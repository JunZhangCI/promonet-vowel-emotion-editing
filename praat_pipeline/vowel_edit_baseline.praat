# Praat vowel-level emotional speech editing baseline
#
# This script implements the conventional baseline described in the project
# proposal. It edits a neutral recording with MFA vowel boundaries and can use
# a matched emotional donor, pair-average changes, or manual changes.
#
# Requires Praat 6.4.06 or newer (createFolder/folderExists scripting support).

form: "Vowel-level Praat editing baseline"
    sentence: "Neutral wav", "../audio/47_16_neu_f.wav"
    sentence: "Neutral TextGrid", "../audio/textgrids/47_16_neu_f.TextGrid"
    sentence: "Donor wav", "../audio/47_16_hap_f.wav"
    sentence: "Donor TextGrid", "../audio/textgrids/47_16_hap_f.TextGrid"
    optionmenu: "Edit mode", 1
        option: "Donor contours"
        option: "Average donor differences"
        option: "Manual changes"
    sentence: "Selected vowel IDs", "all"
    boolean: "Edit pitch", 1
    boolean: "Edit loudness", 1
    boolean: "Edit duration", 1
    real: "Acoustic taper (ms)", "35"
    positive: "Analysis time step (s)", "0.01"
    positive: "Pitch floor (Hz)", "75"
    positive: "Pitch ceiling (Hz)", "600"
    real: "Manual pitch shift (semitones)", "0"
    real: "Manual loudness change (dB)", "0"
    positive: "Manual duration ratio", "1"
    sentence: "Manual override TSV", ""
    sentence: "Phone tier", "phones"
    sentence: "Word tier", "words"
    sentence: "Output directory", "C:/projects/ProMoNet/output/praat_pipeline"
    sentence: "Output prefix", "praat_vowel_edit"
endform

# ------------------------------ Validation ------------------------------

if acoustic_taper < 0
    exitScript: "Acoustic taper cannot be negative."
endif
if pitch_ceiling <= pitch_floor
    exitScript: "Pitch ceiling must be greater than pitch floor."
endif
if edit_pitch = 0 and edit_loudness = 0 and edit_duration = 0
    exitScript: "Select at least one feature: pitch, loudness, or duration."
endif
if phone_tier$ = ""
    exitScript: "Phone tier name cannot be empty."
endif
if output_directory$ = ""
    exitScript: "Output directory cannot be empty."
endif

use_donor = edit_mode <> 3
if not fileReadable (neutral_wav$)
    exitScript: "Neutral WAV is not readable: ", neutral_wav$
endif
if not fileReadable (neutral_TextGrid$)
    exitScript: "Neutral TextGrid is not readable: ", neutral_TextGrid$
endif
if use_donor
    if not fileReadable (donor_wav$)
        exitScript: "Donor WAV is not readable: ", donor_wav$
    endif
    if not fileReadable (donor_TextGrid$)
        exitScript: "Donor TextGrid is not readable: ", donor_TextGrid$
    endif
    if neutral_wav$ = donor_wav$
        exitScript: "Neutral and donor WAV files must be different."
    endif
endif

if not folderExists (output_directory$)
    createFolder (output_directory$)
endif
if not folderExists (output_directory$)
    exitScript: "Could not create output directory: ", output_directory$
endif

safe_prefix$ = replace_regex$ (output_prefix$, "[^A-Za-z0-9._-]", "_", 0)
if safe_prefix$ = ""
    safe_prefix$ = "praat_vowel_edit"
endif

vowel_inventory$ = " AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW "

# ------------------------------ Load input ------------------------------

neutral_sound = Read from file: neutral_wav$
neutral_sound_name$ = selected$ ("Sound")
neutral_channels = Get number of channels
neutral_sample_rate = Get sampling frequency
neutral_sound_start = Get start time
neutral_sound_end = Get end time
if neutral_channels <> 1
    exitScript: "Neutral WAV must be mono; found ", neutral_channels, " channels."
endif

neutral_grid = Read from file: neutral_TextGrid$
neutral_grid_start = Get start time
neutral_grid_end = Get end time
domain_tolerance = max (0.02, 2 / neutral_sample_rate)
if abs (neutral_grid_start - neutral_sound_start) > domain_tolerance or abs (neutral_grid_end - neutral_sound_end) > domain_tolerance
    exitScript: "Neutral WAV/TextGrid time domains differ by more than ", fixed$ (domain_tolerance, 6), " s."
endif

# Praat's "To TextGrid (scale times)" requires exact domain equality.  WAV
# duration is sample-based, while a TextGrid endpoint is often rounded in its
# text file, so align the accepted TextGrid precisely to the Sound domain.
selectObject: neutral_grid
Scale times to: neutral_sound_start, neutral_sound_end
neutral_grid_start = Get start time
neutral_grid_end = Get end time

if use_donor
    donor_sound = Read from file: donor_wav$
    donor_sound_name$ = selected$ ("Sound")
    donor_channels = Get number of channels
    donor_sample_rate = Get sampling frequency
    donor_sound_start = Get start time
    donor_sound_end = Get end time
    if donor_channels <> 1
        exitScript: "Donor WAV must be mono; found ", donor_channels, " channels."
    endif

    donor_grid = Read from file: donor_TextGrid$
    donor_grid_start = Get start time
    donor_grid_end = Get end time
    donor_domain_tolerance = max (0.02, 2 / donor_sample_rate)
    if abs (donor_grid_start - donor_sound_start) > donor_domain_tolerance or abs (donor_grid_end - donor_sound_end) > donor_domain_tolerance
        exitScript: "Donor WAV/TextGrid time domains differ by more than ", fixed$ (donor_domain_tolerance, 6), " s."
    endif

    # Keep donor interval boundaries consistent with donor acoustic measures.
    selectObject: donor_grid
    Scale times to: donor_sound_start, donor_sound_end
    donor_grid_start = Get start time
    donor_grid_end = Get end time
endif

# ------------------------- Find TextGrid tiers --------------------------

selectObject: neutral_grid
neutral_number_of_tiers = Get number of tiers
neutral_phone_tier = 0
neutral_word_tier = 0
for tier_number from 1 to neutral_number_of_tiers
    tier_name$ = Get tier name: tier_number
    if lowerCase$ (tier_name$) = lowerCase$ (phone_tier$)
        neutral_phone_tier = tier_number
    endif
    if word_tier$ <> "" and lowerCase$ (tier_name$) = lowerCase$ (word_tier$)
        neutral_word_tier = tier_number
    endif
endfor
if neutral_phone_tier = 0
    exitScript: "Neutral TextGrid is missing interval tier '", phone_tier$, "'."
endif

if use_donor
    selectObject: donor_grid
    donor_number_of_tiers = Get number of tiers
    donor_phone_tier = 0
    donor_word_tier = 0
    for tier_number from 1 to donor_number_of_tiers
        tier_name$ = Get tier name: tier_number
        if lowerCase$ (tier_name$) = lowerCase$ (phone_tier$)
            donor_phone_tier = tier_number
        endif
        if word_tier$ <> "" and lowerCase$ (tier_name$) = lowerCase$ (word_tier$)
            donor_word_tier = tier_number
        endif
    endfor
    if donor_phone_tier = 0
        exitScript: "Donor TextGrid is missing interval tier '", phone_tier$, "'."
    endif
endif

# -------------------------- Read neutral vowels -------------------------

selectObject: neutral_grid
neutral_phone_intervals = Get number of intervals: neutral_phone_tier
neutral_count = 0
for interval_number from 1 to neutral_phone_intervals
    raw_phone$ = Get label of interval: neutral_phone_tier, interval_number
    phone$ = upperCase$ (raw_phone$)
    normalized_phone$ = replace_regex$ (phone$, "[012]+$", "", 0)
    if index (vowel_inventory$, " " + normalized_phone$ + " ") > 0
        start_time = Get starting point: neutral_phone_tier, interval_number
        end_time = Get end point: neutral_phone_tier, interval_number
        if start_time < neutral_grid_start or end_time > neutral_grid_end or end_time <= start_time
            exitScript: "Invalid neutral vowel interval ", interval_number, ": [", start_time, ", ", end_time, ")."
        endif

        neutral_count += 1
        neutral_phone$ [neutral_count] = phone$
        neutral_normalized$ [neutral_count] = normalized_phone$
        neutral_start [neutral_count] = start_time
        neutral_end [neutral_count] = end_time
        neutral_duration [neutral_count] = end_time - start_time
        neutral_word$ [neutral_count] = ""

        if neutral_word_tier > 0
            word_intervals = Get number of intervals: neutral_word_tier
            best_overlap = 0
            for word_interval from 1 to word_intervals
                candidate_word$ = Get label of interval: neutral_word_tier, word_interval
                if candidate_word$ <> ""
                    word_start = Get starting point: neutral_word_tier, word_interval
                    word_end = Get end point: neutral_word_tier, word_interval
                    overlap = min (end_time, word_end) - max (start_time, word_start)
                    if overlap > best_overlap
                        best_overlap = overlap
                        neutral_word$ [neutral_count] = candidate_word$
                    endif
                endif
            endfor
        endif
    endif
endfor
if neutral_count = 0
    exitScript: "No ARPAbet vowels were found in the neutral phone tier."
endif

for vowel_id from 2 to neutral_count
    if neutral_start [vowel_id] < neutral_end [vowel_id - 1]
        exitScript: "Neutral vowel intervals overlap or are out of order at vowel ", vowel_id, "."
    endif
endfor

# --------------------------- Read donor vowels --------------------------

if use_donor
    selectObject: donor_grid
    donor_phone_intervals = Get number of intervals: donor_phone_tier
    donor_count = 0
    for interval_number from 1 to donor_phone_intervals
        raw_phone$ = Get label of interval: donor_phone_tier, interval_number
        phone$ = upperCase$ (raw_phone$)
        normalized_phone$ = replace_regex$ (phone$, "[012]+$", "", 0)
        if index (vowel_inventory$, " " + normalized_phone$ + " ") > 0
            start_time = Get starting point: donor_phone_tier, interval_number
            end_time = Get end point: donor_phone_tier, interval_number
            if start_time < donor_grid_start or end_time > donor_grid_end or end_time <= start_time
                exitScript: "Invalid donor vowel interval ", interval_number, ": [", start_time, ", ", end_time, ")."
            endif

            donor_count += 1
            donor_phone$ [donor_count] = phone$
            donor_normalized$ [donor_count] = normalized_phone$
            donor_start [donor_count] = start_time
            donor_end [donor_count] = end_time
            donor_duration [donor_count] = end_time - start_time
        endif
    endfor

    if donor_count <> neutral_count
        exitScript: "Vowel count mismatch: neutral has ", neutral_count, " and donor has ", donor_count, ". Correct the TextGrids first."
    endif
    for vowel_id from 1 to neutral_count
        if donor_normalized$ [vowel_id] <> neutral_normalized$ [vowel_id]
            exitScript: "Vowel sequence mismatch at vowel ", vowel_id, ": neutral '", neutral_phone$ [vowel_id], "', donor '", donor_phone$ [vowel_id], "'."
        endif
        if vowel_id > 1 and donor_start [vowel_id] < donor_end [vowel_id - 1]
            exitScript: "Donor vowel intervals overlap or are out of order at vowel ", vowel_id, "."
        endif
    endfor
endif

# -------------------------- Parse vowel selection -----------------------

for vowel_id from 1 to neutral_count
    selected_vowel [vowel_id] = 0
endfor

selection_text$ = lowerCase$ (selected_vowel_IDs$)
selection_text$ = replace$ (selection_text$, ",", " ", 0)
selection_text$ = replace$ (selection_text$, ";", " ", 0)
if selection_text$ = "all"
    for vowel_id from 1 to neutral_count
        selected_vowel [vowel_id] = 1
    endfor
else
    selection_tokens$# = splitByWhitespace$# (selection_text$)
    if size (selection_tokens$#) = 0
        exitScript: "Selected vowel IDs must be 'all' or a comma/space-separated list."
    endif
    for token_number from 1 to size (selection_tokens$#)
        requested_id = number (selection_tokens$# [token_number])
        if requested_id = undefined or requested_id <> round (requested_id)
            exitScript: "Invalid vowel ID: '", selection_tokens$# [token_number], "'."
        endif
        requested_id = round (requested_id)
        if requested_id < 1 or requested_id > neutral_count
            exitScript: "Unknown vowel ID ", requested_id, "; valid IDs are 1 through ", neutral_count, "."
        endif
        selected_vowel [requested_id] = 1
    endfor
endif

selected_count = 0
for vowel_id from 1 to neutral_count
    selected_count += selected_vowel [vowel_id]
endfor
if selected_count = 0
    exitScript: "Select at least one vowel."
endif

# ---------------------- Initialize manual parameters --------------------

for vowel_id from 1 to neutral_count
    manual_pitch [vowel_id] = manual_pitch_shift
    manual_loudness [vowel_id] = manual_loudness_change
    manual_duration [vowel_id] = manual_duration_ratio
    override_seen [vowel_id] = 0
endfor

if edit_mode = 3 and manual_override_TSV$ <> ""
    if not fileReadable (manual_override_TSV$)
        exitScript: "Manual override TSV is not readable: ", manual_override_TSV$
    endif
    override_lines$# = readLinesFromFile$# (manual_override_TSV$)
    for line_number from 1 to size (override_lines$#)
        line$ = override_lines$# [line_number]
        tokens$# = splitByWhitespace$# (line$)
        if size (tokens$#) > 0
            first_token$ = lowerCase$ (tokens$# [1])
            if left$ (first_token$, 1) <> "#" and first_token$ <> "vowel_id"
                if size (tokens$#) <> 4
                    exitScript: "Malformed override TSV line ", line_number, ": expected 4 whitespace-separated columns."
                endif
                override_id = number (tokens$# [1])
                override_pitch = number (tokens$# [2])
                override_loudness = number (tokens$# [3])
                override_duration = number (tokens$# [4])
                if override_id = undefined or override_pitch = undefined or override_loudness = undefined or override_duration = undefined
                    exitScript: "Malformed numeric value in override TSV line ", line_number, "."
                endif
                if override_id <> round (override_id) or override_id < 1 or override_id > neutral_count
                    exitScript: "Invalid vowel_id in override TSV line ", line_number, "."
                endif
                override_id = round (override_id)
                if override_seen [override_id]
                    exitScript: "Duplicate vowel_id ", override_id, " in override TSV."
                endif
                if override_duration <= 0
                    exitScript: "Duration ratio must be positive in override TSV line ", line_number, "."
                endif
                manual_pitch [override_id] = override_pitch
                manual_loudness [override_id] = override_loudness
                manual_duration [override_id] = override_duration
                override_seen [override_id] = 1
            endif
        endif
    endfor
endif

# ------------------------- Acoustic measurements -----------------------

selectObject: neutral_sound
neutral_pitch = To Pitch: analysis_time_step, pitch_floor, pitch_ceiling
selectObject: neutral_sound
neutral_intensity = To Intensity: pitch_floor, analysis_time_step, "yes"

if use_donor
    selectObject: donor_sound
    donor_pitch = To Pitch: analysis_time_step, pitch_floor, pitch_ceiling
    selectObject: donor_sound
    donor_intensity = To Intensity: pitch_floor, analysis_time_step, "yes"
endif

valid_pitch_pairs = 0
sum_pitch_shift = 0
sum_loudness_change = 0
sum_duration_ratio = 0

for vowel_id from 1 to neutral_count
    selectObject: neutral_pitch
    neutral_pitch_mean [vowel_id] = Get mean: neutral_start [vowel_id], neutral_end [vowel_id], "Hertz"
    selectObject: neutral_intensity
    neutral_intensity_mean [vowel_id] = Get mean: neutral_start [vowel_id], neutral_end [vowel_id], "energy"

    donor_pitch_mean [vowel_id] = undefined
    donor_intensity_mean [vowel_id] = undefined
    donor_pitch_shift [vowel_id] = 0
    donor_loudness_change [vowel_id] = 0
    donor_duration_ratio [vowel_id] = 1

    if use_donor
        selectObject: donor_pitch
        donor_pitch_mean [vowel_id] = Get mean: donor_start [vowel_id], donor_end [vowel_id], "Hertz"
        selectObject: donor_intensity
        donor_intensity_mean [vowel_id] = Get mean: donor_start [vowel_id], donor_end [vowel_id], "energy"
        donor_loudness_change [vowel_id] = donor_intensity_mean [vowel_id] - neutral_intensity_mean [vowel_id]
        donor_duration_ratio [vowel_id] = donor_duration [vowel_id] / neutral_duration [vowel_id]

        sum_loudness_change += donor_loudness_change [vowel_id]
        sum_duration_ratio += donor_duration_ratio [vowel_id]
        if neutral_pitch_mean [vowel_id] <> undefined and donor_pitch_mean [vowel_id] <> undefined and neutral_pitch_mean [vowel_id] > 0 and donor_pitch_mean [vowel_id] > 0
            donor_pitch_shift [vowel_id] = 12 * log2 (donor_pitch_mean [vowel_id] / neutral_pitch_mean [vowel_id])
            sum_pitch_shift += donor_pitch_shift [vowel_id]
            valid_pitch_pairs += 1
        endif
    endif
endfor

if use_donor
    average_loudness_change = sum_loudness_change / neutral_count
    average_duration_ratio = sum_duration_ratio / neutral_count
    if valid_pitch_pairs > 0
        average_pitch_shift = sum_pitch_shift / valid_pitch_pairs
    else
        average_pitch_shift = 0
        if edit_mode = 2 and edit_pitch
            exitScript: "No matched vowels contain valid neutral and donor F0 measurements."
        endif
    endif
endif

# -------------------------- Resolve requests ----------------------------

for vowel_id from 1 to neutral_count
    requested_pitch_shift [vowel_id] = 0
    requested_loudness_change [vowel_id] = 0
    requested_duration_ratio [vowel_id] = 1
    effective_taper [vowel_id] = 0
    pitch_fallback_count [vowel_id] = 0
    warning$ [vowel_id] = ""

    if selected_vowel [vowel_id]
        if edit_mode = 1
            requested_pitch_shift [vowel_id] = donor_pitch_shift [vowel_id]
            requested_loudness_change [vowel_id] = donor_loudness_change [vowel_id]
            requested_duration_ratio [vowel_id] = donor_duration_ratio [vowel_id]
        elsif edit_mode = 2
            requested_pitch_shift [vowel_id] = average_pitch_shift
            requested_loudness_change [vowel_id] = average_loudness_change
            requested_duration_ratio [vowel_id] = average_duration_ratio
        else
            requested_pitch_shift [vowel_id] = manual_pitch [vowel_id]
            requested_loudness_change [vowel_id] = manual_loudness [vowel_id]
            requested_duration_ratio [vowel_id] = manual_duration [vowel_id]
        endif

        if not edit_pitch
            requested_pitch_shift [vowel_id] = 0
        endif
        if not edit_loudness
            requested_loudness_change [vowel_id] = 0
        endif
        if not edit_duration
            requested_duration_ratio [vowel_id] = 1
        endif
        if requested_duration_ratio [vowel_id] <= 0
            exitScript: "Duration ratio must be positive for vowel ", vowel_id, "."
        endif
        effective_taper [vowel_id] = min (acoustic_taper / 1000, neutral_duration [vowel_id] / 2)
        if requested_duration_ratio [vowel_id] < 0.5 or requested_duration_ratio [vowel_id] > 2.0
            warning$ [vowel_id] = "extreme_duration_ratio"
        endif
    endif
endfor

# ------------------------- Build edited PitchTier -----------------------

edited_pitch_tier = Create PitchTier: "edited_pitch", neutral_sound_start, neutral_sound_end
pitch_steps = ceiling ((neutral_sound_end - neutral_sound_start) / analysis_time_step)
for step_number from 0 to pitch_steps
    time = min (neutral_sound_start + step_number * analysis_time_step, neutral_sound_end)
    selectObject: neutral_pitch
    neutral_f0 = Get value at time: time, "Hertz", "linear"
    if neutral_f0 <> undefined and neutral_f0 > 0
        edited_f0 = neutral_f0
        active_vowel = 0
        for vowel_id from 1 to neutral_count
            if time >= neutral_start [vowel_id] and time < neutral_end [vowel_id]
                active_vowel = vowel_id
            endif
        endfor

        if active_vowel > 0 and selected_vowel [active_vowel] and edit_pitch
            target_f0 = neutral_f0 * 2 ^ (requested_pitch_shift [active_vowel] / 12)
            if edit_mode = 1
                relative_time = (time - neutral_start [active_vowel]) / neutral_duration [active_vowel]
                mapped_donor_time = donor_start [active_vowel] + relative_time * donor_duration [active_vowel]
                selectObject: donor_pitch
                donor_f0 = Get value at time: mapped_donor_time, "Hertz", "linear"
                if donor_f0 <> undefined and donor_f0 > 0
                    target_f0 = donor_f0
                else
                    target_f0 = neutral_f0
                    pitch_fallback_count [active_vowel] += 1
                endif
            endif

            taper = effective_taper [active_vowel]
            if taper = 0
                weight = 1
            else
                left_weight = (time - neutral_start [active_vowel]) / taper
                right_weight = (neutral_end [active_vowel] - time) / taper
                weight = max (0, min (1, min (left_weight, right_weight)))
            endif
            edited_f0 = neutral_f0 * (1 - weight) + target_f0 * weight
        endif

        selectObject: edited_pitch_tier
        Add point: time, edited_f0
    endif
endfor

# ----------------------- Build loudness gain tier -----------------------

gain_tier = Create IntensityTier: "vowel_gain_db", neutral_sound_start, neutral_sound_end
gain_steps = ceiling ((neutral_sound_end - neutral_sound_start) / analysis_time_step)
for step_number from 0 to gain_steps
    time = min (neutral_sound_start + step_number * analysis_time_step, neutral_sound_end)
    gain_db = 0
    active_vowel = 0
    for vowel_id from 1 to neutral_count
        if time >= neutral_start [vowel_id] and time < neutral_end [vowel_id]
            active_vowel = vowel_id
        endif
    endfor

    if active_vowel > 0 and selected_vowel [active_vowel] and edit_loudness
        target_gain = requested_loudness_change [active_vowel]
        if edit_mode = 1
            relative_time = (time - neutral_start [active_vowel]) / neutral_duration [active_vowel]
            mapped_donor_time = donor_start [active_vowel] + relative_time * donor_duration [active_vowel]
            selectObject: neutral_intensity
            neutral_db = Get value at time: time, "cubic"
            selectObject: donor_intensity
            donor_db = Get value at time: mapped_donor_time, "cubic"
            if neutral_db <> undefined and donor_db <> undefined
                target_gain = donor_db - neutral_db
            else
                target_gain = 0
            endif
        endif

        taper = effective_taper [active_vowel]
        if taper = 0
            weight = 1
        else
            left_weight = (time - neutral_start [active_vowel]) / taper
            right_weight = (neutral_end [active_vowel] - time) / taper
            weight = max (0, min (1, min (left_weight, right_weight)))
        endif
        gain_db = target_gain * weight
    endif

    selectObject: gain_tier
    Add point: time, gain_db
endfor

# Apply the relative dB tier directly. Praat's Sound & IntensityTier Multiply
# command normalizes the peak to 0.9, which would change unedited regions.
selectObject: neutral_sound
adjusted_sound = Copy: "neutral_gain_adjusted"
Formula: ~ self * 10 ^ (object (gain_tier, x) / 20)
selectObject: adjusted_sound
target_intensity = To Intensity: pitch_floor, analysis_time_step, "yes"

# ------------------------- Build DurationTier ---------------------------

duration_tier = Create DurationTier: "vowel_duration", neutral_sound_start, neutral_sound_end
Add point: neutral_sound_start, 1
epsilon = 0.0001

for vowel_id from 1 to neutral_count
    if selected_vowel [vowel_id] and edit_duration
        local_epsilon = min (epsilon, neutral_duration [vowel_id] / 10)
        previous_is_adjacent_selected = 0
        if vowel_id > 1
            if selected_vowel [vowel_id - 1] and edit_duration and abs (neutral_end [vowel_id - 1] - neutral_start [vowel_id]) < 1e-9
                previous_is_adjacent_selected = 1
            endif
        endif

        if not previous_is_adjacent_selected
            left_transition_time = max (neutral_sound_start, neutral_start [vowel_id] - local_epsilon)
            if left_transition_time > neutral_sound_start
                Add point: left_transition_time, 1
            endif
            Add point: neutral_start [vowel_id] + local_epsilon, requested_duration_ratio [vowel_id]
        endif

        Add point: neutral_end [vowel_id] - local_epsilon, requested_duration_ratio [vowel_id]
        right_factor = 1
        if vowel_id < neutral_count
            if selected_vowel [vowel_id + 1] and edit_duration and abs (neutral_start [vowel_id + 1] - neutral_end [vowel_id]) < 1e-9
                right_factor = requested_duration_ratio [vowel_id + 1]
            endif
        endif
        right_transition_time = min (neutral_sound_end, neutral_end [vowel_id] + local_epsilon)
        if right_transition_time < neutral_sound_end
            Add point: right_transition_time, right_factor
        endif
    endif
endfor
Add point: neutral_sound_end, 1

# ------------------------- PSOLA resynthesis ----------------------------

selectObject: adjusted_sound
manipulation = To Manipulation: analysis_time_step, pitch_floor, pitch_ceiling
selectObject: manipulation, edited_pitch_tier
Replace pitch tier
selectObject: manipulation, duration_tier
Replace duration tier
selectObject: manipulation
output_sound = Get resynthesis (overlap-add)
Rename: safe_prefix$

# Compute actual output vowel times with the same DurationTier.
selectObject: neutral_grid, duration_tier
scaled_grid = To TextGrid (scale times)
selectObject: scaled_grid
scaled_phone_intervals = Get number of intervals: neutral_phone_tier
scaled_count = 0
for interval_number from 1 to scaled_phone_intervals
    raw_phone$ = Get label of interval: neutral_phone_tier, interval_number
    phone$ = upperCase$ (raw_phone$)
    normalized_phone$ = replace_regex$ (phone$, "[012]+$", "", 0)
    if index (vowel_inventory$, " " + normalized_phone$ + " ") > 0
        scaled_count += 1
        output_start [scaled_count] = Get starting point: neutral_phone_tier, interval_number
        output_end [scaled_count] = Get end point: neutral_phone_tier, interval_number
        output_duration [scaled_count] = output_end [scaled_count] - output_start [scaled_count]
    endif
endfor
if scaled_count <> neutral_count
    exitScript: "Internal error: scaled TextGrid vowel count changed."
endif

# ------------------------- Clipping protection --------------------------

selectObject: output_sound
output_peak = Get absolute extremum: 0, 0, "none"
safety_gain_db = 0
if output_peak > 0.99
    safety_factor = 0.99 / output_peak
    safety_gain_db = 20 * log10 (safety_factor)
    Scale amplitudes: 0.99
endif

# -------------------------- Output analysis -----------------------------

selectObject: output_sound
output_pitch = To Pitch: analysis_time_step, pitch_floor, pitch_ceiling
selectObject: output_sound
output_intensity = To Intensity: pitch_floor, analysis_time_step, "yes"

for vowel_id from 1 to neutral_count
    selectObject: edited_pitch_tier
    target_pitch_mean [vowel_id] = Get mean (curve): neutral_start [vowel_id], neutral_end [vowel_id]
    selectObject: target_intensity
    target_intensity_mean [vowel_id] = Get mean: neutral_start [vowel_id], neutral_end [vowel_id], "energy"
    target_intensity_mean [vowel_id] += safety_gain_db

    selectObject: output_pitch
    achieved_pitch_mean [vowel_id] = Get mean: output_start [vowel_id], output_end [vowel_id], "Hertz"
    selectObject: output_intensity
    achieved_intensity_mean [vowel_id] = Get mean: output_start [vowel_id], output_end [vowel_id], "energy"

    if pitch_fallback_count [vowel_id] > 0
        if warning$ [vowel_id] <> ""
            warning$ [vowel_id] += ";"
        endif
        warning$ [vowel_id] += "donor_f0_undefined_frames=" + string$ (pitch_fallback_count [vowel_id])
    endif
endfor

# --------------------------- Save artifacts -----------------------------

feature_slug$ = ""
if edit_pitch
    feature_slug$ = "pitch"
endif
if edit_loudness
    if feature_slug$ <> ""
        feature_slug$ += "-"
    endif
    feature_slug$ += "loudness"
endif
if edit_duration
    if feature_slug$ <> ""
        feature_slug$ += "-"
    endif
    feature_slug$ += "duration"
endif

if edit_mode = 1
    mode_slug$ = "donor-contours"
elsif edit_mode = 2
    mode_slug$ = "average-donor"
else
    mode_slug$ = "manual"
endif

clock_parts# = date# ()
timestamp$ = fixed$ (clock_parts# [1], 0)
month$ = fixed$ (clock_parts# [2], 0)
day$ = fixed$ (clock_parts# [3], 0)
hour$ = fixed$ (clock_parts# [4], 0)
minute$ = fixed$ (clock_parts# [5], 0)
second$ = fixed$ (clock_parts# [6], 0)
if clock_parts# [2] < 10
    month$ = "0" + month$
endif
if clock_parts# [3] < 10
    day$ = "0" + day$
endif
if clock_parts# [4] < 10
    hour$ = "0" + hour$
endif
if clock_parts# [5] < 10
    minute$ = "0" + minute$
endif
if clock_parts# [6] < 10
    second$ = "0" + second$
endif
timestamp$ += month$ + day$
timestamp$ += "-"
timestamp$ += hour$ + minute$ + second$

artifact_stem$ = output_directory$ + "/" + safe_prefix$ + "__" + mode_slug$ + "__features-" + feature_slug$ + "__" + timestamp$
wav_path$ = artifact_stem$ + ".wav"
audit_path$ = artifact_stem$ + "_audit.tsv"
collision = 1
collision_number = 1
while collision
    if fileReadable (wav_path$) or fileReadable (audit_path$)
        wav_path$ = artifact_stem$ + "_" + string$ (collision_number) + ".wav"
        audit_path$ = artifact_stem$ + "_" + string$ (collision_number) + "_audit.tsv"
        collision_number += 1
    else
        collision = 0
    endif
endwhile

selectObject: output_sound
Save as WAV file: wav_path$

writeFileLine: audit_path$, "run_timestamp", tab$, "mode", tab$, "vowel_id", tab$, "phone", tab$, "normalized_phone", tab$, "word", tab$, "selected", tab$, "features", tab$, "neutral_start_s", tab$, "neutral_end_s", tab$, "donor_start_s", tab$, "donor_end_s", tab$, "output_start_s", tab$, "output_end_s", tab$, "neutral_pitch_hz", tab$, "donor_pitch_hz", tab$, "requested_pitch_semitones", tab$, "target_pitch_hz", tab$, "achieved_pitch_hz", tab$, "neutral_intensity_db", tab$, "donor_intensity_db", tab$, "requested_loudness_db", tab$, "target_intensity_db", tab$, "achieved_intensity_db", tab$, "requested_duration_ratio", tab$, "target_duration_s", tab$, "achieved_duration_s", tab$, "taper_ms", tab$, "safety_gain_db", tab$, "warning"

for vowel_id from 1 to neutral_count
    selected_features$ = ""
    if selected_vowel [vowel_id]
        if edit_pitch
            selected_features$ = "pitch"
        endif
        if edit_loudness
            if selected_features$ <> ""
                selected_features$ += ","
            endif
            selected_features$ += "loudness"
        endif
        if edit_duration
            if selected_features$ <> ""
                selected_features$ += ","
            endif
            selected_features$ += "duration"
        endif
    endif

    if use_donor
        donor_start_text$ = fixed$ (donor_start [vowel_id], 6)
        donor_end_text$ = fixed$ (donor_end [vowel_id], 6)
        donor_pitch_text$ = fixed$ (donor_pitch_mean [vowel_id], 6)
        donor_intensity_text$ = fixed$ (donor_intensity_mean [vowel_id], 6)
    else
        donor_start_text$ = ""
        donor_end_text$ = ""
        donor_pitch_text$ = ""
        donor_intensity_text$ = ""
    endif

    appendFileLine: audit_path$, timestamp$, tab$, edit_mode$, tab$, vowel_id, tab$, neutral_phone$ [vowel_id], tab$, neutral_normalized$ [vowel_id], tab$, neutral_word$ [vowel_id], tab$, selected_vowel [vowel_id], tab$, selected_features$, tab$, fixed$ (neutral_start [vowel_id], 6), tab$, fixed$ (neutral_end [vowel_id], 6), tab$, donor_start_text$, tab$, donor_end_text$, tab$, fixed$ (output_start [vowel_id], 6), tab$, fixed$ (output_end [vowel_id], 6), tab$, fixed$ (neutral_pitch_mean [vowel_id], 6), tab$, donor_pitch_text$, tab$, fixed$ (requested_pitch_shift [vowel_id], 6), tab$, fixed$ (target_pitch_mean [vowel_id], 6), tab$, fixed$ (achieved_pitch_mean [vowel_id], 6), tab$, fixed$ (neutral_intensity_mean [vowel_id], 6), tab$, donor_intensity_text$, tab$, fixed$ (requested_loudness_change [vowel_id], 6), tab$, fixed$ (target_intensity_mean [vowel_id], 6), tab$, fixed$ (achieved_intensity_mean [vowel_id], 6), tab$, fixed$ (requested_duration_ratio [vowel_id], 6), tab$, fixed$ (output_duration [vowel_id], 6), tab$, fixed$ (output_duration [vowel_id], 6), tab$, fixed$ (effective_taper [vowel_id] * 1000, 3), tab$, fixed$ (safety_gain_db, 6), tab$, warning$ [vowel_id]
endfor

# Keep the generated Sound visible in the GUI, but remove intermediates.
removeObject: neutral_grid, neutral_pitch, neutral_intensity, gain_tier, adjusted_sound, target_intensity, edited_pitch_tier, duration_tier, manipulation, scaled_grid, output_pitch, output_intensity
removeObject: neutral_sound
if use_donor
    removeObject: donor_grid, donor_pitch, donor_intensity, donor_sound
endif
selectObject: output_sound

writeInfoLine: "Praat vowel edit completed."
appendInfoLine: "Mode: ", edit_mode$
appendInfoLine: "Selected vowels: ", selected_count, " of ", neutral_count
appendInfoLine: "WAV: ", wav_path$
appendInfoLine: "Audit: ", audit_path$
if safety_gain_db < 0
    appendInfoLine: "Anti-clipping gain: ", fixed$ (safety_gain_db, 3), " dB"
endif
