"""Regenerate the two readable DNSMOS analysis notebooks."""

from __future__ import annotations

import json
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def markdown(source: str) -> dict:
    return {
        "id": hashlib.sha1(source.encode("utf-8")).hexdigest()[:8],
        "cell_type": "markdown",
        "metadata": {},
        "source": source.splitlines(keepends=True),
    }


def code(source: str) -> dict:
    return {
        "id": hashlib.sha1(source.encode("utf-8")).hexdigest()[:8],
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": source.splitlines(keepends=True),
    }


def write_notebook(path: Path, cells: list[dict]) -> None:
    notebook = {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3 (promonet)",
                "language": "python",
                "name": "python3",
            },
            "language_info": {"name": "python", "version": "3.10"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }
    path.write_text(json.dumps(notebook, indent=1), encoding="utf-8")


write_notebook(
    ROOT / "dnsmos_all_audio_analysis.ipynb",
    [
        markdown("""# DNSMOS Pro quality analysis for all audio

This notebook scores the original, vowel-edit, and Praat groups with the
NISQA-trained DNSMOS Pro checkpoint. DNSMOS Pro predicts speech-quality mean
opinion score (MOS); it is not a speech-recognition intelligibility classifier.
The model revision and preprocessing are pinned for reproducibility."""),
        code("""from pathlib import Path
import os
import pandas as pd
from IPython.display import display

from dnsmos_common import (
    DNSMOSPRO_COMMIT, build_group_inventory, find_project_root,
    score_all_groups,
)

PROJECT_ROOT = find_project_root()
DEVICE = os.environ.get("DNSMOS_DEVICE", "auto")
FORCE_RECOMPUTE = os.environ.get("DNSMOS_FORCE_RECOMPUTE", "false").lower() in {"1", "true", "yes"}
print(f"Project root: {PROJECT_ROOT}")
print(f"DNSMOSPro commit: {DNSMOSPRO_COMMIT}")
print(f"Device request: {DEVICE}")"""),
        markdown("""## 1. Inspect the strict three-group inventory

The notebook stops if the expected 150/149/99 structure changes, so files
cannot silently enter or leave the comparison."""),
        code("""inventory = build_group_inventory(PROJECT_ROOT)
counts = inventory.groupby(["pipeline", "condition"]).size().rename("wav_count")
display(counts.to_frame())
display(inventory.head())"""),
        markdown("""## 2. Score all recordings

Audio is converted to mono 16 kHz and repetitively cropped to 10 seconds,
matching DNSMOSPro's dataset preprocessing. Existing successful rows are reused
when the file and pinned model revision are unchanged."""),
        code("""scored_groups, average_table = score_all_groups(
    PROJECT_ROOT, device=DEVICE, force_recompute=FORCE_RECOMPUTE
)
for name, frame in scored_groups.items():
    print(f"{name}: {len(frame)} successful rows")
display(average_table.style.format("{:.3f}", na_rep="—"))"""),
        markdown("""## 3. Validate saved outputs

The table has pipeline rows and Neutral/Happy/Sad columns. Praat has no neutral
reconstruction, so that cell is intentionally empty."""),
        code("""output_dir = PROJECT_ROOT / "outputs" / "dnsmos"
expected = {
    "original_audio_scores.csv": 150,
    "vowel_edit_pipeline_scores.csv": 149,
    "praat_pipeline_scores.csv": 99,
}
for filename, row_count in expected.items():
    saved = pd.read_csv(output_dir / filename)
    assert len(saved) == row_count
    assert saved["status"].eq("success").all()
summary = pd.read_csv(output_dir / "average_scores_by_pipeline_emotion.csv")
assert summary.shape == (3, 4)
print("Acceptance checks passed for all three DNSMOS groups.")
display(summary.style.format(
    {c: "{:.3f}" for c in ["neutral", "happy", "sad"]}, na_rep="—"
))"""),
    ],
)


write_notebook(
    ROOT / "dnsmos_web_examples.ipynb",
    [
        markdown("""# DNSMOS Pro scores for website examples

Run this notebook only after copying both sentence-47_01 Praat WAVs into
`outputs/web_examples/`. It requires the exact 11-file website manifest, scores
every sample, and generates matching spectrograms."""),
        code("""import os
import pandas as pd
from IPython.display import display

from dnsmos_common import (
    build_web_inventory, find_project_root, generate_web_spectrograms,
    score_web_examples,
)

PROJECT_ROOT = find_project_root()
DEVICE = os.environ.get("DNSMOS_DEVICE", "auto")
FORCE_RECOMPUTE = os.environ.get("DNSMOS_FORCE_RECOMPUTE", "false").lower() in {"1", "true", "yes"}"""),
        markdown("""## 1. Validate the 11-file manifest

This check gives a clear missing/unexpected filename error before the model is
loaded."""),
        code("""inventory = build_web_inventory(PROJECT_ROOT)
assert len(inventory) == 11
display(inventory[["filename", "pipeline", "condition", "feature_set"]])
print("Manifest accepted: 11 unique website WAVs.")"""),
        markdown("## 2. Compute individual DNSMOS Pro scores"),
        code("""scores = score_web_examples(
    PROJECT_ROOT, device=DEVICE, force_recompute=FORCE_RECOMPUTE
)
display(scores[["filename", "dnsmos_mos", "dnsmos_variance"]].style.format(
    {"dnsmos_mos": "{:.3f}", "dnsmos_variance": "{:.3f}"}
))
print(f"Saved: {PROJECT_ROOT / 'outputs' / 'dnsmos' / 'web_example_scores.csv'}")"""),
        markdown("""## 3. Generate comparable spectrograms

All images use the same dB range, frequency range, STFT settings, and
dimensions. Copies are written both beside the source examples and under the
static website image directory."""),
        code("""spectrograms = generate_web_spectrograms(PROJECT_ROOT)
assert len(spectrograms) == 11
for path in spectrograms:
    print(path.relative_to(PROJECT_ROOT))"""),
        markdown("## 4. Final acceptance checks"),
        code("""saved = pd.read_csv(
    PROJECT_ROOT / "outputs" / "dnsmos" / "web_example_scores.csv"
)
assert len(saved) == 11
assert saved["relative_path"].is_unique
assert saved["status"].eq("success").all()
assert saved[["dnsmos_mos", "dnsmos_variance"]].notna().all().all()
assert len(list(
    (PROJECT_ROOT / "docs" / "images" / "spectrograms").glob("*.png")
)) == 11
print("Acceptance checks passed: 11 scores and 11 mirrored spectrograms.")"""),
    ],
)

print("Regenerated DNSMOS notebooks.")
