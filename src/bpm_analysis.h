#ifndef HW_VIDEO_CLIPS_BPM_ANALYSIS_H
#define HW_VIDEO_CLIPS_BPM_ANALYSIS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>

typedef enum HWBPMAnalysisStatus {
    HWBPMAnalysisOK = 0,
    HWBPMAnalysisNoAudio = 1,
    HWBPMAnalysisUnreadable = 2,
    HWBPMAnalysisCancelled = 3,
} HWBPMAnalysisStatus;

typedef struct HWBPMCancellationToken {
    _Atomic uint32_t storage;
} HWBPMCancellationToken;

typedef struct HWWaveformPeak {
    float low_minimum;
    float low_maximum;
    float mid_minimum;
    float mid_maximum;
    float high_minimum;
    float high_maximum;
} HWWaveformPeak;

_Static_assert(sizeof(_Atomic uint32_t) == sizeof(uint32_t),
    "atomic cancellation storage must remain 32 bits");
_Static_assert(_Alignof(_Atomic uint32_t) == _Alignof(uint32_t),
    "atomic cancellation storage must retain uint32_t alignment");
_Static_assert(sizeof(HWBPMCancellationToken) == sizeof(uint32_t),
    "cancellation token ABI must remain one uint32_t");
_Static_assert(_Alignof(HWBPMCancellationToken) == _Alignof(uint32_t),
    "cancellation token ABI must retain uint32_t alignment");
_Static_assert(sizeof(HWWaveformPeak) == sizeof(float) * 6,
    "waveform peak ABI must remain six floats");
_Static_assert(_Alignof(HWWaveformPeak) == _Alignof(float),
    "waveform peak ABI must retain float alignment");

void hw_bpm_cancellation_token_init(HWBPMCancellationToken *token);
void hw_bpm_cancellation_token_cancel(HWBPMCancellationToken *token);
bool hw_bpm_cancellation_token_is_cancelled(
    const HWBPMCancellationToken *token
);

HWBPMAnalysisStatus hw_bpm_copy_onset_envelope(
    const char *path,
    const HWBPMCancellationToken *cancellation_token,
    float **values,
    size_t *count,
    double *rate_hz
);

void hw_bpm_free_onset_envelope(float *values);

HWBPMAnalysisStatus hw_waveform_copy_peaks(
    const char *path,
    const HWBPMCancellationToken *cancellation_token,
    HWWaveformPeak **peaks,
    size_t *count,
    double *rate_hz
);

void hw_waveform_free_peaks(HWWaveformPeak *peaks);

#endif
