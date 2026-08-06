package main

foreign import metronome_bridge "system:System.framework"
foreign metronome_bridge {
	hw_host_time_now :: proc "c" () -> u64 ---
	hw_host_time_after_seconds :: proc "c" (host_time: u64, seconds: f64) -> u64 ---
	hw_host_time_before_seconds :: proc "c" (host_time: u64, seconds: f64) -> u64 ---
	hw_metronome_create :: proc "c" (engine, mixer: Id) -> rawptr ---
	hw_metronome_destroy :: proc "c" (metronome: rawptr, engine: Id) ---
	hw_metronome_stop :: proc "c" (metronome: rawptr) ---
	hw_metronome_set_volume :: proc "c" (metronome: rawptr, volume: f32) ---
	hw_metronome_schedule :: proc "c" (
		metronome: rawptr,
		host_time: u64,
		accent: bool,
	) -> bool ---
	hw_metronome_play :: proc "c" (metronome: rawptr) ---
	hw_audio_player_play_at_host_time :: proc "c" (
		player: Id,
		host_time: u64,
	) -> bool ---
}
