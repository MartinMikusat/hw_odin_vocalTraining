package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import os "core:os/old"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "base:runtime"

BPM_Corpus_Clip :: struct {
	id:                    string,
	title:                 string,
	artist:                string,
	path:                  string,
	expected_bpm:          f64,
	accepted_alternatives: []f64,
	character:             string,
}

BPM_Corpus_Manifest :: struct {
	revision: int,
	clips:    []BPM_Corpus_Clip,
}

bpm_evaluation_matches :: proc(estimate: BPM_Estimate, expected: f64) -> bool {
	return bpm_estimate_auto_applicable(estimate) &&
	       math.abs(estimate.bpm-expected) <= 2
}

@(test)
bpm_evaluation_counts_only_auto_applicable_primary_estimates_test :: proc(
	t: ^testing.T,
) {
	primary := BPM_Estimate{bpm=128, confidence=0.8, valid=true}
	testing.expect(t, bpm_evaluation_matches(primary, 128))

	ambiguous := primary
	ambiguous.bpm = 64
	ambiguous.alternatives[0] = 128
	ambiguous.alternative_count = 1
	testing.expect(t, !bpm_evaluation_matches(ambiguous, 128))

	low_confidence := primary
	low_confidence.confidence = BPM_AUTO_APPLY_MIN_CONFIDENCE - 0.01
	testing.expect(t, !bpm_evaluation_matches(low_confidence, 128))
}

@(test)
bpm_native_estimator_meets_real_music_corpus_gate_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	manifest_path, found := os.lookup_env("HW_VIDEO_CLIPS_BPM_CORPUS_MANIFEST")
	defer delete(manifest_path)
	if !found {
		fmt.println("BPM corpus: SKIP (manifest environment is not configured)")
		return
	}
	bytes, read_ok := os.read_entire_file(manifest_path, context.temp_allocator)
	testing.expect(t, read_ok)
	if !read_ok {return}
	manifest: BPM_Corpus_Manifest
	decode_error := json.unmarshal(bytes, &manifest, .JSON, context.temp_allocator)
	testing.expect(t, decode_error == nil)
	if decode_error != nil {return}
	testing.expect_value(t, manifest.revision, 1)
	testing.expect(t, len(manifest.clips) > 0)

	manifest_directory := filepath.dir(manifest_path)
	available := 0
	passed := 0
	started := time.tick_now()
	for clip in manifest.clips {
		audio_path, join_error := filepath.join(
			[]string{manifest_directory, clip.path},
			context.temp_allocator,
		)
		if join_error != nil || !os.exists(audio_path) {
			fmt.printf("BPM corpus: SKIP %s (local audio unavailable)\n", clip.id)
			continue
		}
		available += 1
		path_c := strings.clone_to_cstring(audio_path, context.temp_allocator)
		values: [^]f32
		count: uint
		rate_hz: f64
		status := hw_bpm_copy_onset_envelope(path_c, nil, &values, &count, &rate_hz)
		if status != .OK || values == nil || count == 0 {
			fmt.printf("BPM corpus: FAIL %3.0f %-32s decode=%v\n", clip.expected_bpm, clip.title, status)
			continue
		}
		estimate := estimate_bpm_from_onset_envelope(values[:count], rate_hz)
		hw_bpm_free_onset_envelope(values)
		matched := bpm_evaluation_matches(estimate, clip.expected_bpm)
		if matched {passed += 1}
		fmt.printf(
			"BPM corpus: %s expected=%6.1f primary=%6.1f confidence=%.3f alternatives=%v title=%s\n",
			matched ? "PASS" : "FAIL",
			clip.expected_bpm,
			estimate.bpm,
			estimate.confidence,
			estimate.alternatives[:estimate.alternative_count],
			clip.title,
		)
	}
	elapsed := time.tick_since(started)
	fmt.printf("BPM corpus: summary %d/%d passed in %v\n", passed, available, elapsed)
	if available == 0 {
		fmt.println("BPM corpus: SKIP (no local audio files)")
		return
	}
	testing.expect(t, available == len(manifest.clips))
	testing.expect(t, passed*100 >= available*80)
}
