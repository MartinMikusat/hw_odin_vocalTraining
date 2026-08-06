package main

foreign import bpm_analysis_bridge "system:System.framework"
foreign bpm_analysis_bridge {
	hw_bpm_cancellation_token_init :: proc "c" (token: ^BPM_Cancellation_Token) ---
	hw_bpm_cancellation_token_cancel :: proc "c" (token: ^BPM_Cancellation_Token) ---
	hw_bpm_cancellation_token_is_cancelled :: proc "c" (
		token: ^BPM_Cancellation_Token,
	) -> bool ---
	hw_bpm_copy_onset_envelope :: proc "c" (
		path: cstring,
		cancellation_token: ^BPM_Cancellation_Token,
		values: ^[^]f32,
		count: ^uint,
		rate_hz: ^f64,
	) -> BPM_Analysis_Status ---
	hw_bpm_free_onset_envelope :: proc "c" (values: [^]f32) ---
	hw_waveform_copy_peaks :: proc "c" (
		path: cstring,
		cancellation_token: ^BPM_Cancellation_Token,
		values: ^[^]f32,
		count: ^uint,
		rate_hz: ^f64,
	) -> BPM_Analysis_Status ---
	hw_waveform_free_peaks :: proc "c" (values: [^]f32) ---
}

BPM_Cancellation_Token :: struct {
	storage: u32,
}

#assert(size_of(BPM_Cancellation_Token) == size_of(u32))
#assert(align_of(BPM_Cancellation_Token) == align_of(u32))

BPM_Analysis_Status :: enum i32 {
	OK          = 0,
	No_Audio    = 1,
	Unreadable  = 2,
	Cancelled   = 3,
}
