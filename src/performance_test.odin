package main

import "core:testing"

when ODIN_DEBUG {
	@(test)
	performance_percentiles_use_nearest_rank_test :: proc(t: ^testing.T) {
		values := []f64{4, 1, 5, 2, 3}
		result := perf_percentiles(values)
		testing.expect_value(t, result.p50_ms, 3.0)
		testing.expect_value(t, result.p95_ms, 5.0)
		testing.expect_value(t, result.p99_ms, 5.0)
		testing.expect_value(t, result.worst_ms, 5.0)
	}
}
