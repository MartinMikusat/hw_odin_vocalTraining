#ifndef HW_VIDEO_CLIPS_METRONOME_H
#define HW_VIDEO_CLIPS_METRONOME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct HWMetronome HWMetronome;

uint64_t hw_host_time_now(void);
uint64_t hw_host_time_after_seconds(uint64_t host_time, double seconds);
uint64_t hw_host_time_before_seconds(uint64_t host_time, double seconds);
HWMetronome *hw_metronome_create(void *engine, void *mixer);
void hw_metronome_destroy(HWMetronome *metronome, void *engine);
void hw_metronome_stop(HWMetronome *metronome);
void hw_metronome_set_volume(HWMetronome *metronome, float volume);
bool hw_metronome_schedule(
    HWMetronome *metronome,
    uint64_t host_time,
    bool accent
);
void hw_metronome_play(HWMetronome *metronome);
bool hw_audio_player_play_at_host_time(void *player, uint64_t host_time);

#endif
