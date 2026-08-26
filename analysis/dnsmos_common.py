"""Shared DNSMOS Pro scoring and web-spectrogram helpers.

The implementation follows the official DNSMOSPro NISQA inference example and
training preprocessing while keeping generated scores and plots inside this
project.  The pinned TorchScript checkpoint is downloaded only when missing.
"""

from __future__ import annotations

import hashlib
import math
import os
import re
import shutil
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import soundfile as sf
import torch
from scipy.signal import get_window, resample_poly


DNSMOSPRO_COMMIT = "72f0fa4f71a41e70f12718be214665b1bf4fcbec"
DNSMOSPRO_CHECKPOINT = "runs/NISQA/model_best.pt"
DNSMOSPRO_MODEL_URL = (
    "https://raw.githubusercontent.com/fcumlin/DNSMOSPro/"
    f"{DNSMOSPRO_COMMIT}/{DNSMOSPRO_CHECKPOINT}"
)
INFERENCE_SAMPLE_RATE = 16_000
INFERENCE_SECONDS = 10
INFERENCE_SAMPLES = INFERENCE_SAMPLE_RATE * INFERENCE_SECONDS
CHECKPOINT_EVERY = 10

RESULT_COLUMNS = [
    "audio_id",
    "relative_path",
    "filename",
    "pipeline",
    "condition",
    "speaker",
    "sentence_id",
    "source_emotion",
    "donor_emotion",
    "feature_set",
    "original_sample_rate",
    "original_channels",
    "duration_seconds",
    "file_size_bytes",
    "modified_time_utc",
    "model_name",
    "model_checkpoint",
    "model_commit",
    "model_sha256",
    "inference_sample_rate",
    "inference_seconds",
    "processed_at_utc",
    "dnsmos_mos",
    "dnsmos_variance",
    "status",
    "error_message",
]

NATURAL_PATTERN = re.compile(
    r"^(?P<speaker>\d+)_(?P<sentence>\d{2})_(?P<emotion>hap|neu|sad)_[fm]$"
)
VOWEL_EDIT_PATTERN = re.compile(
    r"^(?P<speaker>\d+)_(?P<sentence>\d{2})_neu_[fm]__from__"
    r"(?P=speaker)_(?P=sentence)_(?P<donor>hap|sad)_[fm]__"
)
VOWEL_RECON_PATTERN = re.compile(
    r"^(?P<speaker>\d+)_(?P<sentence>\d{2})_neu_[fm]__reconstruction__"
)
PRAAT_PATTERN = re.compile(
    r"^(?P<speaker>\d+)_(?P<sentence>\d{2})_neu_from_(?P<donor>hap|sad)__"
)

EXPECTED_GROUP_COUNTS = {
    "original": 150,
    "vowel_edit_pipeline": 149,
    "praat_pipeline": 99,
}

EXPECTED_WEB_FILES = {
    "neu_original.wav": ("original", "original", "neu", "", "natural"),
    "hap_original.wav": ("original", "original", "hap", "", "natural"),
    "neu_reconstruct.wav": (
        "vowel_edit_pipeline",
        "neu_reconstruct",
        "neu",
        "",
        "reconstruction",
    ),
    "neu-to-hap_pitch.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "pitch",
    ),
    "neu-to-hap_loudness.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "loudness",
    ),
    "neu-to-hap_periodicity.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "periodicity",
    ),
    "neu-to-hap_duration.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "duration",
    ),
    "neu-to-hap_ppg.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "ppg",
    ),
    "neu-to-hap_all.wav": (
        "vowel_edit_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "all",
    ),
    "praat_neu-to-hap.wav": (
        "praat_pipeline",
        "neu_to_hap",
        "neu",
        "hap",
        "pitch-loudness-duration",
    ),
    "praat_neu-to-sad.wav": (
        "praat_pipeline",
        "neu_to_sad",
        "neu",
        "sad",
        "pitch-loudness-duration",
    ),
}


def find_project_root(start: Path | None = None) -> Path:
    """Find the project root from either the root or ``analysis/``."""
    current = (start or Path.cwd()).resolve()
    for candidate in (current, *current.parents):
        if (candidate / "audio").is_dir() and (candidate / "outputs").is_dir():
            return candidate
    raise FileNotFoundError(f"Could not find the ProMoNet project above {current}")


def _relative_metadata(path: Path, project_root: Path) -> dict[str, object]:
    stat = path.stat()
    return {
        "audio_id": path.stem,
        "relative_path": path.relative_to(project_root).as_posix(),
        "filename": path.name,
        "file_size_bytes": int(stat.st_size),
        "modified_time_utc": datetime.fromtimestamp(
            stat.st_mtime, tz=timezone.utc
        ).isoformat(),
        "_path": path,
    }


def build_group_inventory(project_root: Path) -> pd.DataFrame:
    """Discover the three requested analysis groups with strict parsing."""
    rows: list[dict[str, object]] = []

    for path in sorted((project_root / "audio").glob("*.wav")):
        match = NATURAL_PATTERN.fullmatch(path.stem)
        if match is None:
            continue
        rows.append(
            {
                **_relative_metadata(path, project_root),
                "pipeline": "original",
                "condition": "original",
                "speaker": match.group("speaker"),
                "sentence_id": match.group("sentence"),
                "source_emotion": match.group("emotion"),
                "donor_emotion": "",
                "feature_set": "natural",
            }
        )

    for path in sorted(
        (project_root / "outputs" / "vowel_edit_pipeline").glob("*.wav")
    ):
        edit = VOWEL_EDIT_PATTERN.match(path.stem)
        reconstruction = VOWEL_RECON_PATTERN.match(path.stem)
        if edit is not None:
            donor = edit.group("donor")
            row = {
                "condition": f"neu_to_{donor}",
                "speaker": edit.group("speaker"),
                "sentence_id": edit.group("sentence"),
                "donor_emotion": donor,
                "feature_set": "pitch-loudness-periodicity-duration-ppg",
            }
        elif reconstruction is not None:
            row = {
                "condition": "neu_reconstruct",
                "speaker": reconstruction.group("speaker"),
                "sentence_id": reconstruction.group("sentence"),
                "donor_emotion": "",
                "feature_set": "reconstruction",
            }
        else:
            raise ValueError(f"Unrecognized vowel-edit WAV: {path.name}")
        rows.append(
            {
                **_relative_metadata(path, project_root),
                "pipeline": "vowel_edit_pipeline",
                "source_emotion": "neu",
                **row,
            }
        )

    for path in sorted(
        (project_root / "outputs" / "praat_pipeline").rglob("*.wav")
    ):
        match = PRAAT_PATTERN.match(path.stem)
        if match is None:
            raise ValueError(f"Unrecognized Praat WAV: {path.name}")
        donor = match.group("donor")
        rows.append(
            {
                **_relative_metadata(path, project_root),
                "pipeline": "praat_pipeline",
                "condition": f"neu_to_{donor}",
                "speaker": match.group("speaker"),
                "sentence_id": match.group("sentence"),
                "source_emotion": "neu",
                "donor_emotion": donor,
                "feature_set": "pitch-loudness-duration",
            }
        )

    inventory = pd.DataFrame(rows)
    if inventory.empty:
        raise FileNotFoundError("No analysis WAV files were found")
    if inventory["relative_path"].duplicated().any():
        raise ValueError("The DNSMOS inventory contains duplicate paths")
    counts = inventory.groupby("pipeline").size().to_dict()
    if counts != EXPECTED_GROUP_COUNTS:
        raise ValueError(
            f"Unexpected DNSMOS group counts: {counts}; "
            f"expected {EXPECTED_GROUP_COUNTS}"
        )
    return inventory.sort_values(
        ["pipeline", "condition", "speaker", "sentence_id", "relative_path"]
    ).reset_index(drop=True)


def build_web_inventory(project_root: Path) -> pd.DataFrame:
    """Build and validate the fixed 11-file website sample manifest."""
    web_dir = project_root / "outputs" / "web_examples"
    discovered = {path.name: path for path in web_dir.glob("*.wav")}
    missing = sorted(set(EXPECTED_WEB_FILES) - set(discovered))
    unexpected = sorted(set(discovered) - set(EXPECTED_WEB_FILES))
    if missing or unexpected or len(discovered) != 11:
        raise ValueError(
            "Expected exactly the 11 website WAVs after copying both Praat "
            f"examples. Missing={missing}; unexpected={unexpected}"
        )

    rows = []
    for filename, metadata in EXPECTED_WEB_FILES.items():
        pipeline, condition, emotion, donor, feature_set = metadata
        path = discovered[filename]
        rows.append(
            {
                **_relative_metadata(path, project_root),
                "pipeline": pipeline,
                "condition": condition,
                "speaker": "47",
                "sentence_id": "01",
                "source_emotion": emotion,
                "donor_emotion": donor,
                "feature_set": feature_set,
            }
        )
    inventory = pd.DataFrame(rows)
    if inventory["relative_path"].duplicated().any():
        raise ValueError("The website manifest contains duplicate paths")
    return inventory.reset_index(drop=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_model(project_root: Path) -> tuple[Path, str]:
    """Download the pinned NISQA checkpoint once and return its SHA-256."""
    model_dir = project_root / ".cache" / "dnsmospro" / DNSMOSPRO_COMMIT
    model_dir.mkdir(parents=True, exist_ok=True)
    model_path = model_dir / "nisqa_model_best.pt"
    if not model_path.is_file() or model_path.stat().st_size == 0:
        temporary = model_path.with_suffix(".pt.download")
        print(f"Downloading pinned DNSMOS Pro NISQA model to {model_path} ...")
        urllib.request.urlretrieve(DNSMOSPRO_MODEL_URL, temporary)
        os.replace(temporary, model_path)
    return model_path, _sha256(model_path)


def resolve_device(requested: str = "auto") -> torch.device:
    requested = requested.lower()
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if requested.startswith("cuda") and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but is unavailable")
    return torch.device(requested)


def load_model(project_root: Path, device: torch.device):
    model_path, model_sha256 = ensure_model(project_root)
    model = torch.jit.load(str(model_path), map_location=device)
    model.eval()
    return model, model_sha256


def prepare_audio(path: Path) -> tuple[np.ndarray, object]:
    """Match DNSMOSPro's 16 kHz repetitive 10-second crop."""
    info = sf.info(path)
    signal, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    signal = signal.mean(axis=1)
    if signal.size == 0 or not np.isfinite(signal).all():
        raise ValueError("Audio is empty or contains non-finite samples")
    if sample_rate != INFERENCE_SAMPLE_RATE:
        divisor = math.gcd(int(sample_rate), INFERENCE_SAMPLE_RATE)
        signal = resample_poly(
            signal,
            up=INFERENCE_SAMPLE_RATE // divisor,
            down=int(sample_rate) // divisor,
        )
    repeats = max(1, math.ceil(INFERENCE_SAMPLES / signal.size))
    signal = np.tile(signal, repeats)[:INFERENCE_SAMPLES]
    if signal.shape != (INFERENCE_SAMPLES,):
        raise AssertionError(f"Unexpected prepared shape: {signal.shape}")
    return signal.astype(np.float32, copy=False), info


def official_stft(signal: np.ndarray) -> np.ndarray:
    """Reproduce ``DNSMOSPro/utils.py::stft`` defaults."""
    spectrum = _centered_stft(signal, n_fft=320, hop_length=160)
    magnitude = np.abs(spectrum)
    return np.log10(np.clip(magnitude, 10**-7, 10**7))


def _centered_stft(
    signal: np.ndarray, n_fft: int, hop_length: int
) -> np.ndarray:
    """NumPy equivalent of librosa's centered Hann-window STFT."""
    padded = np.pad(signal, (n_fft // 2, n_fft // 2), mode="constant")
    frames = np.lib.stride_tricks.sliding_window_view(padded, n_fft)[::hop_length]
    window = get_window("hann", n_fft, fftbins=True).astype(np.float32)
    return np.fft.rfft(frames * window[None, :], n=n_fft, axis=1)


def score_one(
    row: pd.Series,
    model,
    model_sha256: str,
    device: torch.device,
) -> dict[str, object]:
    path = Path(row["_path"])
    signal, info = prepare_audio(path)
    spectrum = torch.from_numpy(official_stft(signal)).to(
        device=device, dtype=torch.float32
    )
    with torch.inference_mode():
        prediction = model(spectrum[None, None, ...]).squeeze(0)
    values = prediction.detach().cpu().numpy().astype(float)
    if values.shape != (2,) or not np.isfinite(values).all():
        raise ValueError(f"Expected finite mean/variance, received {values}")

    result = {key: row.get(key, "") for key in RESULT_COLUMNS}
    result.update(
        {
            "original_sample_rate": int(info.samplerate),
            "original_channels": int(info.channels),
            "duration_seconds": float(info.duration),
            "model_name": "DNSMOS Pro (NISQA)",
            "model_checkpoint": DNSMOSPRO_CHECKPOINT,
            "model_commit": DNSMOSPRO_COMMIT,
            "model_sha256": model_sha256,
            "inference_sample_rate": INFERENCE_SAMPLE_RATE,
            "inference_seconds": INFERENCE_SECONDS,
            "processed_at_utc": datetime.now(timezone.utc).isoformat(),
            "dnsmos_mos": float(values[0]),
            "dnsmos_variance": float(values[1]),
            "status": "success",
            "error_message": "",
        }
    )
    return result


def _identity_key(row: pd.Series | dict[str, object]) -> tuple[object, ...]:
    return (
        str(row["relative_path"]),
        int(row["file_size_bytes"]),
        str(row["modified_time_utc"]),
        DNSMOSPRO_COMMIT,
    )


def score_inventory(
    inventory: pd.DataFrame,
    output_path: Path,
    project_root: Path,
    device_name: str = "auto",
    force_recompute: bool = False,
) -> pd.DataFrame:
    """Score an inventory with safe checkpointing and unchanged-row reuse."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    existing = pd.DataFrame(columns=RESULT_COLUMNS)
    if output_path.is_file() and not force_recompute:
        candidate = pd.read_csv(
            output_path,
            dtype={"speaker": "string", "sentence_id": "string"},
            keep_default_na=False,
        )
        if set(RESULT_COLUMNS).issubset(candidate.columns):
            existing = candidate[RESULT_COLUMNS]
    cached = {
        _identity_key(row): row.to_dict()
        for _, row in existing[existing["status"].eq("success")].iterrows()
        if row["model_commit"] == DNSMOSPRO_COMMIT
    }

    rows: list[dict[str, object]] = []
    pending: list[pd.Series] = []
    for _, row in inventory.iterrows():
        key = _identity_key(row)
        if key in cached:
            rows.append(cached[key])
        else:
            pending.append(row)

    device = resolve_device(device_name)
    model = model_sha256 = None
    if pending:
        model, model_sha256 = load_model(project_root, device)
    print(
        f"{output_path.name}: {len(inventory)} selected, "
        f"{len(rows)} reused, {len(pending)} requiring inference on {device}"
    )

    def save() -> pd.DataFrame:
        frame = pd.DataFrame(rows)
        for column in RESULT_COLUMNS:
            if column not in frame:
                frame[column] = ""
        frame = frame[RESULT_COLUMNS].sort_values(
            ["pipeline", "condition", "speaker", "sentence_id", "relative_path"]
        ).reset_index(drop=True)
        temporary = output_path.with_suffix(output_path.suffix + ".tmp")
        frame.to_csv(temporary, index=False)
        os.replace(temporary, output_path)
        return frame

    for index, row in enumerate(pending, start=1):
        try:
            result = score_one(row, model, str(model_sha256), device)
        except Exception as error:
            result = {key: row.get(key, "") for key in RESULT_COLUMNS}
            result.update(
                {
                    "model_name": "DNSMOS Pro (NISQA)",
                    "model_checkpoint": DNSMOSPRO_CHECKPOINT,
                    "model_commit": DNSMOSPRO_COMMIT,
                    "model_sha256": str(model_sha256 or ""),
                    "inference_sample_rate": INFERENCE_SAMPLE_RATE,
                    "inference_seconds": INFERENCE_SECONDS,
                    "processed_at_utc": datetime.now(timezone.utc).isoformat(),
                    "status": "error",
                    "error_message": f"{type(error).__name__}: {error}",
                }
            )
            print(f"ERROR {row['relative_path']}: {result['error_message']}")
        rows.append(result)
        if index % CHECKPOINT_EVERY == 0:
            save()
    results = save()
    validate_scores(results, len(inventory), output_path.name)
    return results


def validate_scores(results: pd.DataFrame, expected: int, label: str) -> None:
    if len(results) != expected:
        raise AssertionError(f"{label}: expected {expected} rows, found {len(results)}")
    if results["relative_path"].duplicated().any():
        raise AssertionError(f"{label}: duplicate paths")
    failed = results[~results["status"].eq("success")]
    if not failed.empty:
        raise RuntimeError(
            f"{label}: {len(failed)} scores failed\n"
            + failed[["relative_path", "error_message"]].to_string(index=False)
        )
    values = results[["dnsmos_mos", "dnsmos_variance"]].to_numpy(dtype=float)
    if not np.isfinite(values).all():
        raise AssertionError(f"{label}: non-finite DNSMOS output")
    if (results["dnsmos_variance"].astype(float) < 0).any():
        raise AssertionError(f"{label}: negative variance")


def score_all_groups(
    project_root: Path,
    device: str = "auto",
    force_recompute: bool = False,
) -> tuple[dict[str, pd.DataFrame], pd.DataFrame]:
    inventory = build_group_inventory(project_root)
    output_dir = project_root / "outputs" / "dnsmos"
    filenames = {
        "original": "original_audio_scores.csv",
        "vowel_edit_pipeline": "vowel_edit_pipeline_scores.csv",
        "praat_pipeline": "praat_pipeline_scores.csv",
    }
    scored: dict[str, pd.DataFrame] = {}
    for pipeline, expected_count in EXPECTED_GROUP_COUNTS.items():
        group = inventory[inventory["pipeline"].eq(pipeline)].copy()
        if len(group) != expected_count:
            raise AssertionError(f"Unexpected {pipeline} inventory count")
        scored[pipeline] = score_inventory(
            group,
            output_dir / filenames[pipeline],
            project_root,
            device_name=device,
            force_recompute=force_recompute,
        )

    combined = pd.concat(scored.values(), ignore_index=True)
    successful = combined[combined["status"].eq("success")].copy()
    emotion_condition = np.select(
        [
            successful["pipeline"].eq("original"),
            successful["condition"].eq("neu_reconstruct"),
        ],
        [successful["source_emotion"], "neu"],
        default=successful["donor_emotion"],
    )
    successful["average_emotion"] = emotion_condition
    long_summary = (
        successful.groupby(["pipeline", "average_emotion"], as_index=False)
        .agg(
            mean_dnsmos_mos=("dnsmos_mos", "mean"),
            standard_deviation=("dnsmos_mos", "std"),
            n=("dnsmos_mos", "size"),
        )
    )
    mean_table = long_summary.pivot(
        index="pipeline", columns="average_emotion", values="mean_dnsmos_mos"
    ).reindex(
        index=["original", "vowel_edit_pipeline", "praat_pipeline"],
        columns=["neu", "hap", "sad"],
    )
    mean_table.index.name = "pipeline"
    mean_table.columns = ["neutral", "happy", "sad"]
    mean_table.reset_index().to_csv(
        output_dir / "average_scores_by_pipeline_emotion.csv", index=False
    )
    return scored, mean_table


def score_web_examples(
    project_root: Path,
    device: str = "auto",
    force_recompute: bool = False,
) -> pd.DataFrame:
    inventory = build_web_inventory(project_root)
    output_path = project_root / "outputs" / "dnsmos" / "web_example_scores.csv"
    return score_inventory(
        inventory,
        output_path,
        project_root,
        device_name=device,
        force_recompute=force_recompute,
    )


def generate_web_spectrograms(project_root: Path) -> list[Path]:
    """Generate matching spectrograms for the validated website manifest."""
    inventory = build_web_inventory(project_root)
    output_dir = project_root / "outputs" / "web_examples"
    docs_dir = project_root / "docs" / "images" / "spectrograms"
    docs_dir.mkdir(parents=True, exist_ok=True)
    generated: list[Path] = []
    plt.rcParams.update(
        {
            "font.size": 9,
            "axes.titlesize": 10,
            "axes.labelsize": 9,
            "figure.facecolor": "white",
            "axes.facecolor": "#081c2c",
        }
    )
    for _, row in inventory.iterrows():
        source_path = Path(row["_path"])
        info = sf.info(source_path)
        signal, _ = sf.read(source_path, dtype="float32", always_2d=True)
        signal = signal.mean(axis=1)
        if info.samplerate != INFERENCE_SAMPLE_RATE:
            divisor = math.gcd(int(info.samplerate), INFERENCE_SAMPLE_RATE)
            signal = resample_poly(
                signal,
                up=INFERENCE_SAMPLE_RATE // divisor,
                down=int(info.samplerate) // divisor,
            )
        spectrum = _centered_stft(signal, n_fft=1024, hop_length=256).T
        magnitude = np.maximum(np.abs(spectrum), 1e-10)
        db = 20.0 * np.log10(magnitude)
        db -= float(db.max())
        frequencies = np.fft.rfftfreq(1024, d=1.0 / INFERENCE_SAMPLE_RATE)
        times = np.arange(db.shape[1]) * 256 / INFERENCE_SAMPLE_RATE
        fig, ax = plt.subplots(figsize=(6.0, 2.35))
        ax.pcolormesh(
            times,
            frequencies / 1000.0,
            db,
            shading="auto",
            cmap="magma",
            vmin=-80,
            vmax=0,
        )
        ax.set_ylim(0, 8)
        ax.set_xlim(0, max(float(times[-1]), 0.01))
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Frequency (kHz)")
        ax.set_title(str(row["feature_set"]).replace("-", " ").title())
        ax.grid(False)
        fig.tight_layout(pad=0.7)
        output_path = output_dir / f"{Path(row['filename']).stem}_spectrogram.png"
        fig.savefig(output_path, dpi=180, bbox_inches="tight", facecolor="white")
        plt.close(fig)
        shutil.copy2(output_path, docs_dir / output_path.name)
        generated.append(output_path)
    if len(generated) != 11 or any(path.stat().st_size == 0 for path in generated):
        raise AssertionError("Expected 11 non-empty spectrogram files")
    return generated
