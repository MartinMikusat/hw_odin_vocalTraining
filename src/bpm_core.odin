package main

import "core:math"

BPM_MIN_ENVELOPE_SAMPLES               :: 32
BPM_MIN_DISTINCT_ONSETS                :: 4
BPM_ENERGY_EPSILON                     :: 1.0e-12
BPM_MIN_AUTOCORRELATION                :: 0.12
BPM_MIN_SCORE_CONTRAST                  :: 0.05
BPM_MIN_SCORE_SIGNIFICANCE              :: 2.0
BPM_HARMONIC_SUPPORT_WEIGHT             :: 0.10
BPM_SUBHARMONIC_SUPPORT_WEIGHT          :: 0.05
BPM_PEAK_NEIGHBORHOOD                  :: 2
BPM_CANDIDATE_SEPARATION               :: 3
BPM_MAX_SEARCHED_LAGS                  :: 4096
BPM_FUNDAMENTAL_SCORE_RATIO            :: 0.70
BPM_FUNDAMENTAL_MAX_DIVISOR_ORDER      :: 4
BPM_FUNDAMENTAL_LAG_RATIO_TOLERANCE    :: 0.10
BPM_FUNDAMENTAL_MIN_SCORE_SIGNIFICANCE :: 2.5
BPM_PARABOLIC_DENOMINATOR_EPSILON      :: 1.0e-12
BPM_MAX_FRACTIONAL_LAG_OFFSET          :: 0.5
BPM_PARABOLIC_OFFSET_SCALE             :: 1.25
BPM_ALTERNATIVE_EQUIVALENCE_THRESHOLD :: 0.001
BPM_ALTERNATIVE_MIN_SCORE              :: 0.20
BPM_ALTERNATIVE_SCORE_RATIO            :: 0.55
BPM_CONFIDENCE_STRENGTH_WEIGHT         :: 0.40
BPM_CONFIDENCE_PROMINENCE_WEIGHT       :: 0.25
BPM_CONFIDENCE_SEPARATION_WEIGHT       :: 0.35
BPM_PHASE_MIN_CONFIDENCE               :: 0.08
BPM_ANALYSIS_WINDOW_CENTER_SECONDS     :: 1024.0 / 22050.0

BPM_Estimate :: struct {
	bpm:               f64,
	confidence:        f32,
	alternatives:      [2]f64,
	alternative_count: int,
	beat_period_seconds: f64,
	beat_phase_seconds: f64,
	phase_confidence: f32,
	phase_valid: bool,
	valid:              bool,
}

bpm_envelope_sample_linear :: proc(envelope: []f32, position: f64) -> f64 {
	left := int(math.floor(position))
	if left < 0 || left >= len(envelope) {return 0}
	right := min(left + 1, len(envelope) - 1)
	fraction := position - f64(left)
	return f64(envelope[left]) * (1-fraction) +
	       f64(envelope[right]) * fraction
}

bpm_estimate_phase :: proc(
	envelope: []f32,
	envelope_rate_hz, period_samples: f64,
) -> (phase_seconds: f64, confidence: f32, valid: bool) {
	phase_count := int(math.round(period_samples))
	if phase_count < 2 || phase_count > len(envelope) {return}
	best_phase := 0
	best_score := -math.INF_F64
	second_score := -math.INF_F64
	for phase in 0 ..< phase_count {
		score := 0.0
		position := f64(phase)
		for position < f64(len(envelope)) {
			score += bpm_envelope_sample_linear(envelope, position)
			position += period_samples
		}
		if score > best_score {
			second_score = best_score
			best_score = score
			best_phase = phase
		} else if score > second_score {
			second_score = score
		}
	}
	if best_score <= BPM_ENERGY_EPSILON {return}
	confidence = f32(clamp(
		(best_score-max(0.0, second_score))/best_score,
		0.0,
		1.0,
	))
	period_seconds := period_samples / envelope_rate_hz
	phase_seconds = math.mod(
		f64(best_phase)/envelope_rate_hz + BPM_ANALYSIS_WINDOW_CENTER_SECONDS,
		period_seconds,
	)
	valid = confidence >= BPM_PHASE_MIN_CONFIDENCE
	return
}

bpm_value_is_finite :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

bpm_beat_grid_valid :: proc(period, offset: f64, confidence: f32) -> bool {
	if !bpm_value_is_finite(period) || !bpm_value_is_finite(offset) ||
	   confidence < 0 || confidence > 1 {
		return false
	}
	if period == 0 {return offset == 0 && confidence == 0}
	return period >= 0.25 && period <= 1.5 &&
	       offset >= 0 && offset < period*4
}

bpm_normalize_grid_offset :: proc(offset, period: f64) -> f64 {
	if period <= 0 {return 0}
	bar := period * 4
	result := math.mod(offset, bar)
	if result < 0 {result += bar}
	return result
}

bpm_autocorrelation :: proc(
	envelope: []f32,
	mean, _: f64,
	lag: int,
) -> f64 {
	if lag <= 0 || lag >= len(envelope) {return 0}
	correlation := 0.0
	left_energy := 0.0
	right_energy := 0.0
	for index in 0 ..< len(envelope)-lag {
		left := f64(envelope[index]) - mean
		right := f64(envelope[index+lag]) - mean
		correlation += left * right
		left_energy += left * left
		right_energy += right * right
	}
	denominator := math.sqrt(left_energy * right_energy)
	if denominator <= BPM_ENERGY_EPSILON {return 0}
	return correlation / denominator
}

bpm_candidate_score :: proc(
	envelope: []f32,
	mean, total_energy: f64,
	lag, minimum_lag, maximum_lag: int,
) -> f64 {
	primary := bpm_autocorrelation(envelope, mean, total_energy, lag)
	score := primary
	harmonic_lag := lag * 2
	if harmonic_lag <= maximum_lag {
		score += BPM_HARMONIC_SUPPORT_WEIGHT *
			max(0.0, bpm_autocorrelation(envelope, mean, total_energy, harmonic_lag))
	}
	if lag%2 == 0 && lag/2 >= minimum_lag {
		score += BPM_SUBHARMONIC_SUPPORT_WEIGHT *
			max(0.0, bpm_autocorrelation(envelope, mean, total_energy, lag/2))
	}
	return score
}

bpm_candidate_is_accepted :: proc(
	score, score_mean, score_deviation, minimum_significance: f64,
) -> bool {
	score_contrast := score-score_mean
	return score >= BPM_MIN_AUTOCORRELATION &&
	       score_contrast >= BPM_MIN_SCORE_CONTRAST &&
	       score_deviation > BPM_ENERGY_EPSILON &&
	       score_contrast/score_deviation >= minimum_significance
}

bpm_fractional_peak_lag :: proc(
	envelope: []f32,
	mean, total_energy: f64,
	lag, minimum_lag, maximum_lag: int,
) -> f64 {
	if lag <= minimum_lag || lag >= maximum_lag {return f64(lag)}
	left := bpm_candidate_score(
		envelope, mean, total_energy, lag-1, minimum_lag, maximum_lag,
	)
	center := bpm_candidate_score(
		envelope, mean, total_energy, lag, minimum_lag, maximum_lag,
	)
	right := bpm_candidate_score(
		envelope, mean, total_energy, lag+1, minimum_lag, maximum_lag,
	)
	denominator := left - 2.0*center + right
	if denominator >= -BPM_PARABOLIC_DENOMINATOR_EPSILON {
		return f64(lag)
	}
	offset := BPM_PARABOLIC_OFFSET_SCALE * 0.5 * (left-right) / denominator
	offset = clamp(
		offset,
		-BPM_MAX_FRACTIONAL_LAG_OFFSET,
		BPM_MAX_FRACTIONAL_LAG_OFFSET,
	)
	return f64(lag) + offset
}

bpm_add_alternative :: proc(
	estimate: ^BPM_Estimate,
	bpm, score, best_score, minimum_bpm, maximum_bpm: f64,
) {
	if bpm < minimum_bpm || bpm > maximum_bpm ||
	   score < BPM_ALTERNATIVE_MIN_SCORE ||
	   score < best_score*BPM_ALTERNATIVE_SCORE_RATIO ||
	   math.abs(bpm-estimate.bpm) < BPM_ALTERNATIVE_EQUIVALENCE_THRESHOLD ||
	   estimate.alternative_count >= len(estimate.alternatives) {
		return
	}
	for index in 0 ..< estimate.alternative_count {
		if math.abs(estimate.alternatives[index]-bpm) < BPM_ALTERNATIVE_EQUIVALENCE_THRESHOLD {
			return
		}
	}
	estimate.alternatives[estimate.alternative_count] = bpm
	estimate.alternative_count += 1
}

estimate_bpm_from_onset_envelope :: proc(
	envelope: []f32,
	envelope_rate_hz: f64,
	minimum_bpm := 40.0,
	maximum_bpm := 240.0,
) -> BPM_Estimate {
	result: BPM_Estimate
	if len(envelope) < BPM_MIN_ENVELOPE_SAMPLES ||
	   !bpm_value_is_finite(envelope_rate_hz) || envelope_rate_hz <= 0 ||
	   !bpm_value_is_finite(minimum_bpm) || minimum_bpm <= 0 ||
	   !bpm_value_is_finite(maximum_bpm) || maximum_bpm <= minimum_bpm {
		return result
	}

	mean := 0.0
	for sample in envelope {
		value := f64(sample)
		if !bpm_value_is_finite(value) {return result}
		mean += value
	}
	mean /= f64(len(envelope))

	total_energy := 0.0
	for sample in envelope {
		centered := f64(sample) - mean
		total_energy += centered * centered
	}
	if total_energy <= BPM_ENERGY_EPSILON {return result}
	rms := math.sqrt(total_energy / f64(len(envelope)))
	onset_threshold := mean + rms
	distinct_onsets := 0
	above_threshold := false
	for sample in envelope {
		above := f64(sample) > onset_threshold
		if above && !above_threshold {
			distinct_onsets += 1
		}
		above_threshold = above
	}
	if distinct_onsets < BPM_MIN_DISTINCT_ONSETS {return result}

	minimum_lag_value := 60.0 * envelope_rate_hz / maximum_bpm
	maximum_lag_value := 60.0 * envelope_rate_hz / minimum_bpm
	if !bpm_value_is_finite(minimum_lag_value) ||
	   !bpm_value_is_finite(maximum_lag_value) ||
	   minimum_lag_value > f64(len(envelope)/2) ||
	   maximum_lag_value < 1 {
		return result
	}
	minimum_lag := max(1, int(math.ceil(minimum_lag_value)))
	maximum_lag := min(
		len(envelope)/2,
		int(math.floor(min(maximum_lag_value, f64(len(envelope)/2)))),
	)
	if minimum_lag > maximum_lag ||
	   maximum_lag-minimum_lag+1 > BPM_MAX_SEARCHED_LAGS {
		return result
	}

	best_lag := 0
	best_score := -math.INF_F64
	score_sum := 0.0
	score_squared_sum := 0.0
	score_count := maximum_lag-minimum_lag+1
	for lag in minimum_lag ..= maximum_lag {
		score := bpm_candidate_score(
			envelope, mean, total_energy, lag, minimum_lag, maximum_lag,
		)
		score_sum += score
		score_squared_sum += score * score
		if score > best_score {
			best_score = score
			best_lag = lag
		}
	}
	if best_lag == 0 {return result}

	score_mean := score_sum / f64(score_count)
	score_variance := max(
		0.0,
		score_squared_sum/f64(score_count) - score_mean*score_mean,
	)
	score_deviation := math.sqrt(score_variance)
	if !bpm_candidate_is_accepted(
		best_score,
		score_mean,
		score_deviation,
		BPM_MIN_SCORE_SIGNIFICANCE,
	) {
		return result
	}

	// Quantized onset positions can make a short-period candidate repeat as a
	// stronger multi-period alias. Replace the validated global winner only when
	// a shorter local peak has both independent significance and a bounded,
	// near-integer divisor relationship to that winner.
	global_best_lag := best_lag
	global_best_score := best_score
	fundamental_threshold := global_best_score * BPM_FUNDAMENTAL_SCORE_RATIO
	for lag in minimum_lag ..< global_best_lag {
		score := bpm_candidate_score(
			envelope, mean, total_energy, lag, minimum_lag, maximum_lag,
		)
		if score < fundamental_threshold ||
		   !bpm_candidate_is_accepted(
			   score,
			   score_mean,
			   score_deviation,
			   BPM_FUNDAMENTAL_MIN_SCORE_SIGNIFICANCE,
		   ) {
			continue
		}
		harmonically_related := false
		lag_ratio := f64(global_best_lag) / f64(lag)
		for divisor_order in 2 ..= BPM_FUNDAMENTAL_MAX_DIVISOR_ORDER {
			if math.abs(lag_ratio-f64(divisor_order)) <=
			   BPM_FUNDAMENTAL_LAG_RATIO_TOLERANCE {
				harmonically_related = true
				break
			}
		}
		if !harmonically_related {continue}
		left_score := -math.INF_F64
		right_score := -math.INF_F64
		if lag > minimum_lag {
			left_score = bpm_candidate_score(
				envelope, mean, total_energy, lag-1, minimum_lag, maximum_lag,
			)
		}
		if lag < maximum_lag {
			right_score = bpm_candidate_score(
				envelope, mean, total_energy, lag+1, minimum_lag, maximum_lag,
			)
		}
		if score >= left_score && score >= right_score {
			best_lag = lag
			best_score = score
			break
		}
	}

	second_score := 0.0
	half_double_score := 0.0
	for lag in minimum_lag ..= maximum_lag {
		if abs(lag-best_lag) <= BPM_CANDIDATE_SEPARATION {continue}
		score := bpm_candidate_score(
			envelope, mean, total_energy, lag, minimum_lag, maximum_lag,
		)
		half_double_distance := min(abs(lag-best_lag*2), abs(best_lag-lag*2))
		if half_double_distance <= 1 {
			half_double_score = max(half_double_score, score)
		} else {
			second_score = max(second_score, score)
		}
	}
	neighbor_score := 0.0
	for offset in -BPM_PEAK_NEIGHBORHOOD ..= BPM_PEAK_NEIGHBORHOOD {
		if offset == 0 {continue}
		lag := best_lag + offset
		if lag < minimum_lag || lag > maximum_lag {continue}
		neighbor_score = max(
			neighbor_score,
			bpm_candidate_score(
				envelope, mean, total_energy, lag, minimum_lag, maximum_lag,
			),
		)
	}

	fractional_lag := bpm_fractional_peak_lag(
		envelope,
		mean,
		total_energy,
		best_lag,
		minimum_lag,
		maximum_lag,
	)
	result.bpm = 60.0 * envelope_rate_hz / fractional_lag
	result.beat_period_seconds = fractional_lag / envelope_rate_hz
	result.beat_phase_seconds,
	result.phase_confidence,
	result.phase_valid = bpm_estimate_phase(
		envelope,
		envelope_rate_hz,
		fractional_lag,
	)
	strength := clamp(best_score, 0.0, 1.0)
	prominence := clamp(best_score-neighbor_score, 0.0, 1.0)
	strongest_competitor := max(second_score, half_double_score)
	separation := clamp(
		(best_score-strongest_competitor)/max(best_score, BPM_ENERGY_EPSILON),
		0.0,
		1.0,
	)
	result.confidence = f32(clamp(
		BPM_CONFIDENCE_STRENGTH_WEIGHT*strength +
			BPM_CONFIDENCE_PROMINENCE_WEIGHT*prominence +
			BPM_CONFIDENCE_SEPARATION_WEIGHT*separation,
		0.0,
		1.0,
	))
	result.valid = true

	half_lag := best_lag * 2
	if half_lag <= maximum_lag {
		half_score := bpm_candidate_score(
			envelope, mean, total_energy, half_lag, minimum_lag, maximum_lag,
		)
		bpm_add_alternative(
			&result,
			result.bpm/2,
			half_score,
			best_score,
			minimum_bpm,
			maximum_bpm,
		)
	}
	double_lag := int(math.round(f64(best_lag)/2))
	if double_lag >= minimum_lag {
		double_score := bpm_candidate_score(
			envelope, mean, total_energy, double_lag, minimum_lag, maximum_lag,
		)
		bpm_add_alternative(
			&result,
			result.bpm*2,
			double_score,
			best_score,
			minimum_bpm,
			maximum_bpm,
		)
	}
	return result
}
