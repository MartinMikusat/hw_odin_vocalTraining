#import "bpm_analysis.h"

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>

#include <math.h>
#include <float.h>
#include <stdlib.h>
#include <string.h>

static const double HW_BPM_SAMPLE_RATE = 22050.0;
static const double HW_WAVEFORM_LOW_CUTOFF_HZ = 200.0;
static const double HW_WAVEFORM_HIGH_CUTOFF_HZ = 2000.0;
enum {
    HW_BPM_FRAME_LENGTH = 2048,
    HW_BPM_HOP_LENGTH = 512,
    HW_BPM_LOG2_FRAME_LENGTH = 11,
    HW_BPM_LOCAL_MEAN_LENGTH = 8,
    HW_WAVEFORM_SAMPLES_PER_PEAK = 16,
};

typedef struct {
    FFTSetup fftSetup;
    float *window;
    float *frame;
    size_t frameFill;
    size_t samplesSinceLastFrame;
    float *windowed;
    float *real;
    float *imaginary;
    float *magnitudes;
    float *previousMagnitudes;
    float *differences;
    float *flux;
    size_t fluxCount;
    size_t fluxCapacity;
} HWBPMAnalyzer;

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
    float z1;
    float z2;
} HWWaveformBiquad;

static void hw_waveform_biquad_configure(
    HWWaveformBiquad *filter,
    double cutoffHz,
    bool highPass
) {
    const double omega = 2.0 * M_PI * cutoffHz / HW_BPM_SAMPLE_RATE;
    const double cosine = cos(omega);
    const double sine = sin(omega);
    const double alpha = sine / (2.0 * M_SQRT1_2);
    const double a0 = 1.0 + alpha;
    if (highPass) {
        filter->b0 = (float)((1.0 + cosine) / (2.0 * a0));
        filter->b1 = (float)(-(1.0 + cosine) / a0);
        filter->b2 = filter->b0;
    } else {
        filter->b0 = (float)((1.0 - cosine) / (2.0 * a0));
        filter->b1 = (float)((1.0 - cosine) / a0);
        filter->b2 = filter->b0;
    }
    filter->a1 = (float)(-2.0 * cosine / a0);
    filter->a2 = (float)((1.0 - alpha) / a0);
    filter->z1 = 0.0f;
    filter->z2 = 0.0f;
}

static float hw_waveform_biquad_process(
    HWWaveformBiquad *filter,
    float sample
) {
    const float output = filter->b0 * sample + filter->z1;
    filter->z1 = filter->b1 * sample - filter->a1 * output + filter->z2;
    filter->z2 = filter->b2 * sample - filter->a2 * output;
    return output;
}

static HWWaveformPeak hw_waveform_empty_peak(void) {
    return (HWWaveformPeak){
        .low_minimum = FLT_MAX,
        .low_maximum = -FLT_MAX,
        .mid_minimum = FLT_MAX,
        .mid_maximum = -FLT_MAX,
        .high_minimum = FLT_MAX,
        .high_maximum = -FLT_MAX,
    };
}

static bool hw_waveform_reserve_peak(
    HWWaveformPeak **peaks,
    size_t count,
    size_t *capacity
) {
    if (count < *capacity) {
        return true;
    }
    size_t nextCapacity = *capacity == 0 ? 1024 : *capacity * 2;
    if (nextCapacity < *capacity ||
        nextCapacity > SIZE_MAX / sizeof(HWWaveformPeak)) {
        return false;
    }
    HWWaveformPeak *resized = realloc(
        *peaks,
        nextCapacity * sizeof(HWWaveformPeak));
    if (resized == NULL) {
        return false;
    }
    *peaks = resized;
    *capacity = nextCapacity;
    return true;
}

void hw_bpm_cancellation_token_init(HWBPMCancellationToken *token) {
    if (token != NULL) {
        atomic_store_explicit(&token->storage, UINT32_C(0), memory_order_release);
    }
}

void hw_bpm_cancellation_token_cancel(HWBPMCancellationToken *token) {
    if (token != NULL) {
        atomic_store_explicit(&token->storage, UINT32_C(1), memory_order_release);
    }
}

bool hw_bpm_cancellation_token_is_cancelled(
    const HWBPMCancellationToken *token
) {
    return token != NULL &&
        atomic_load_explicit(&token->storage, memory_order_acquire) != UINT32_C(0);
}

static void hw_bpm_analyzer_destroy(HWBPMAnalyzer *analyzer) {
    if (analyzer == NULL) {
        return;
    }
    if (analyzer->fftSetup != NULL) {
        vDSP_destroy_fftsetup(analyzer->fftSetup);
    }
    free(analyzer->window);
    free(analyzer->frame);
    free(analyzer->windowed);
    free(analyzer->real);
    free(analyzer->imaginary);
    free(analyzer->magnitudes);
    free(analyzer->previousMagnitudes);
    free(analyzer->differences);
    free(analyzer->flux);
    memset(analyzer, 0, sizeof(*analyzer));
}

static bool hw_bpm_analyzer_create(HWBPMAnalyzer *analyzer) {
    const size_t frameLength = (size_t)HW_BPM_FRAME_LENGTH;
    const size_t binCount = frameLength / 2;
    memset(analyzer, 0, sizeof(*analyzer));
    analyzer->fftSetup = vDSP_create_fftsetup(
        HW_BPM_LOG2_FRAME_LENGTH,
        kFFTRadix2);
    analyzer->window = malloc(frameLength * sizeof(float));
    analyzer->frame = calloc(frameLength, sizeof(float));
    analyzer->windowed = malloc(frameLength * sizeof(float));
    analyzer->real = malloc(binCount * sizeof(float));
    analyzer->imaginary = malloc(binCount * sizeof(float));
    analyzer->magnitudes = malloc(binCount * sizeof(float));
    analyzer->previousMagnitudes = calloc(binCount, sizeof(float));
    analyzer->differences = malloc(binCount * sizeof(float));
    if (analyzer->fftSetup == NULL || analyzer->window == NULL ||
        analyzer->frame == NULL || analyzer->windowed == NULL ||
        analyzer->real == NULL || analyzer->imaginary == NULL ||
        analyzer->magnitudes == NULL ||
        analyzer->previousMagnitudes == NULL ||
        analyzer->differences == NULL) {
        hw_bpm_analyzer_destroy(analyzer);
        return false;
    }
    vDSP_hann_window(
        analyzer->window,
        HW_BPM_FRAME_LENGTH,
        vDSP_HANN_NORM);
    return true;
}

static bool hw_bpm_append_flux(HWBPMAnalyzer *analyzer, float value) {
    if (!isfinite(value)) {
        return false;
    }
    if (analyzer->fluxCount == analyzer->fluxCapacity) {
        size_t capacity = analyzer->fluxCapacity == 0 ? 256 :
            analyzer->fluxCapacity * 2;
        if (capacity < analyzer->fluxCapacity ||
            capacity > SIZE_MAX / sizeof(float)) {
            return false;
        }
        float *resized = realloc(analyzer->flux, capacity * sizeof(float));
        if (resized == NULL) {
            return false;
        }
        analyzer->flux = resized;
        analyzer->fluxCapacity = capacity;
    }
    analyzer->flux[analyzer->fluxCount++] = value;
    return true;
}

static bool hw_bpm_analyze_frame(HWBPMAnalyzer *analyzer) {
    const vDSP_Length packedBinCount = HW_BPM_FRAME_LENGTH / 2;
    const vDSP_Length ordinaryBinCount = packedBinCount - 1;
    vDSP_vmul(
        analyzer->frame,
        1,
        analyzer->window,
        1,
        analyzer->windowed,
        1,
        HW_BPM_FRAME_LENGTH);
    DSPSplitComplex split = {
        .realp = analyzer->real,
        .imagp = analyzer->imaginary,
    };
    vDSP_ctoz(
        (const DSPComplex *)analyzer->windowed,
        2,
        &split,
        1,
        packedBinCount);
    vDSP_fft_zrip(
        analyzer->fftSetup,
        &split,
        1,
        HW_BPM_LOG2_FRAME_LENGTH,
        FFT_FORWARD);
    // vDSP's packed real FFT stores DC in realp[0] and Nyquist in imagp[0].
    // They are two real bins, not one complex bin. Onset flux intentionally
    // excludes both and computes magnitudes only for ordinary bins 1..N/2-1.
    DSPSplitComplex ordinaryBins = {
        .realp = analyzer->real + 1,
        .imagp = analyzer->imaginary + 1,
    };
    vDSP_zvabs(
        &ordinaryBins,
        1,
        analyzer->magnitudes,
        1,
        ordinaryBinCount);
    vDSP_vsub(
        analyzer->previousMagnitudes,
        1,
        analyzer->magnitudes,
        1,
        analyzer->differences,
        1,
        ordinaryBinCount);
    const float zero = 0.0f;
    vDSP_vthr(
        analyzer->differences,
        1,
        &zero,
        analyzer->differences,
        1,
        ordinaryBinCount);
    float flux = 0.0f;
    vDSP_sve(analyzer->differences, 1, &flux, ordinaryBinCount);
    memcpy(
        analyzer->previousMagnitudes,
        analyzer->magnitudes,
        (size_t)ordinaryBinCount * sizeof(float));
    return hw_bpm_append_flux(analyzer, flux);
}

static bool hw_bpm_analyze_samples(
    HWBPMAnalyzer *analyzer,
    const float *samples,
    size_t count,
    const HWBPMCancellationToken *cancellationToken
) {
    size_t offset = 0;
    while (offset < count) {
        if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
            return false;
        }
        size_t remaining = (size_t)HW_BPM_FRAME_LENGTH - analyzer->frameFill;
        size_t copied = count - offset < remaining ? count - offset : remaining;
        memcpy(
            analyzer->frame + analyzer->frameFill,
            samples + offset,
            copied * sizeof(float));
        analyzer->frameFill += copied;
        analyzer->samplesSinceLastFrame += copied;
        offset += copied;
        if (analyzer->frameFill == (size_t)HW_BPM_FRAME_LENGTH) {
            if (!hw_bpm_analyze_frame(analyzer)) {
                return false;
            }
            const size_t retained =
                (size_t)HW_BPM_FRAME_LENGTH - HW_BPM_HOP_LENGTH;
            memmove(
                analyzer->frame,
                analyzer->frame + HW_BPM_HOP_LENGTH,
                retained * sizeof(float));
            analyzer->frameFill = retained;
            analyzer->samplesSinceLastFrame = 0;
        }
    }
    return true;
}

static bool hw_bpm_normalize_flux(HWBPMAnalyzer *analyzer) {
    if (analyzer->fluxCount == 0) {
        return false;
    }
    double rollingSum = 0.0;
    float history[HW_BPM_LOCAL_MEAN_LENGTH] = {0};
    size_t historyCount = 0;
    size_t historyIndex = 0;
    for (size_t index = 0; index < analyzer->fluxCount; index += 1) {
        float rawFlux = analyzer->flux[index];
        // The baseline is prior history only. Insert the current flux after
        // subtraction so a peak never attenuates itself.
        float mean = historyCount == 0 ? 0.0f :
            (float)(rollingSum / (double)historyCount);
        analyzer->flux[index] = fmaxf(rawFlux - mean, 0.0f);
        if (historyCount == HW_BPM_LOCAL_MEAN_LENGTH) {
            rollingSum -= history[historyIndex];
        } else {
            historyCount += 1;
        }
        history[historyIndex] = rawFlux;
        historyIndex = (historyIndex + 1) % HW_BPM_LOCAL_MEAN_LENGTH;
        rollingSum += rawFlux;
    }
    float maximum = 0.0f;
    vDSP_maxv(
        analyzer->flux,
        1,
        &maximum,
        (vDSP_Length)analyzer->fluxCount);
    if (!isfinite(maximum)) {
        return false;
    }
    if (maximum > 0.0f) {
        float scale = 1.0f / maximum;
        vDSP_vsmul(
            analyzer->flux,
            1,
            &scale,
            analyzer->flux,
            1,
            (vDSP_Length)analyzer->fluxCount);
    }
    return true;
}

static HWBPMAnalysisStatus hw_bpm_wait_for_audio_tracks(
    AVURLAsset *asset,
    const HWBPMCancellationToken *cancellationToken,
    NSArray<AVAssetTrack *> **audioTracks
) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack *> *loadedTracks = nil;
    __block NSError *loadError = nil;
    [asset loadTracksWithMediaType:AVMediaTypeAudio
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        loadedTracks = tracks;
        loadError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    for (;;) {
        if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
            return HWBPMAnalysisCancelled;
        }
        long result = dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC));
        if (result == 0) {
            break;
        }
    }
    if (loadError != nil || loadedTracks == nil) {
        return HWBPMAnalysisUnreadable;
    }
    if (loadedTracks.count == 0) {
        return HWBPMAnalysisNoAudio;
    }
    *audioTracks = loadedTracks;
    return HWBPMAnalysisOK;
}

static bool hw_bpm_sample_buffer_is_expected_pcm(
    CMSampleBufferRef sampleBuffer,
    const AudioBufferList *bufferList
) {
    CMAudioFormatDescriptionRef description =
        CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *format = description == NULL ? NULL :
        CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (format == NULL || format->mFormatID != kAudioFormatLinearPCM ||
        format->mSampleRate != HW_BPM_SAMPLE_RATE ||
        format->mChannelsPerFrame != 1 ||
        (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
        format->mBitsPerChannel != 32 || bufferList->mNumberBuffers != 1 ||
        bufferList->mBuffers[0].mNumberChannels != 1 ||
        bufferList->mBuffers[0].mData == NULL ||
        bufferList->mBuffers[0].mDataByteSize % sizeof(float) != 0) {
        return false;
    }
    return true;
}

HWBPMAnalysisStatus hw_bpm_copy_onset_envelope(
    const char *path,
    const HWBPMCancellationToken *cancellationToken,
    float **values,
    size_t *count,
    double *rate_hz
) {
    if (values != NULL) {
        *values = NULL;
    }
    if (count != NULL) {
        *count = 0;
    }
    if (rate_hz != NULL) {
        *rate_hz = 0.0;
    }
    if (path == NULL || path[0] == '\0' || values == NULL || count == NULL ||
        rate_hz == NULL) {
        return HWBPMAnalysisUnreadable;
    }
    if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
        return HWBPMAnalysisCancelled;
    }

    @autoreleasepool {
        NSString *filePath = [NSString stringWithUTF8String:path];
        if (filePath == nil ||
            ![[NSFileManager defaultManager] isReadableFileAtPath:filePath]) {
            return HWBPMAnalysisUnreadable;
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:
            [NSURL fileURLWithPath:filePath isDirectory:NO] options:nil];
        NSArray<AVAssetTrack *> *audioTracks = nil;
        HWBPMAnalysisStatus trackStatus = hw_bpm_wait_for_audio_tracks(
            asset,
            cancellationToken,
            &audioTracks);
        if (trackStatus != HWBPMAnalysisOK) {
            return trackStatus;
        }

        NSError *readerError = nil;
        AVAssetReader *reader = [[AVAssetReader alloc]
            initWithAsset:asset error:&readerError];
        if (reader == nil || readerError != nil) {
            return HWBPMAnalysisUnreadable;
        }
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(HW_BPM_SAMPLE_RATE),
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:audioTracks.firstObject outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            return HWBPMAnalysisUnreadable;
        }
        [reader addOutput:output];
        if (![reader startReading]) {
            return HWBPMAnalysisUnreadable;
        }

        HWBPMAnalyzer analyzer;
        if (!hw_bpm_analyzer_create(&analyzer)) {
            [reader cancelReading];
            return HWBPMAnalysisUnreadable;
        }
        HWBPMAnalysisStatus status = HWBPMAnalysisOK;
        while (reader.status == AVAssetReaderStatusReading) {
            if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
                status = HWBPMAnalysisCancelled;
                [reader cancelReading];
                break;
            }
            CMSampleBufferRef sampleBuffer =
                [output copyNextSampleBuffer];
            if (sampleBuffer == NULL) {
                break;
            }
            CMBlockBufferRef retainedBlock = NULL;
            AudioBufferList bufferList;
            OSStatus bufferStatus =
                CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    NULL,
                    &bufferList,
                    sizeof(bufferList),
                    NULL,
                    NULL,
                    kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                    &retainedBlock);
            if (bufferStatus != noErr ||
                !hw_bpm_sample_buffer_is_expected_pcm(sampleBuffer, &bufferList)) {
                status = HWBPMAnalysisUnreadable;
            } else {
                size_t sampleCount =
                    bufferList.mBuffers[0].mDataByteSize / sizeof(float);
                const float *samples = bufferList.mBuffers[0].mData;
                for (size_t index = 0; index < sampleCount; index += 1) {
                    if (!isfinite(samples[index])) {
                        status = HWBPMAnalysisUnreadable;
                        break;
                    }
                }
                if (status == HWBPMAnalysisOK &&
                    !hw_bpm_analyze_samples(
                        &analyzer, samples, sampleCount, cancellationToken)) {
                    status = hw_bpm_cancellation_token_is_cancelled(cancellationToken) ?
                        HWBPMAnalysisCancelled : HWBPMAnalysisUnreadable;
                }
            }
            if (retainedBlock != NULL) {
                CFRelease(retainedBlock);
            }
            CFRelease(sampleBuffer);
            if (status != HWBPMAnalysisOK) {
                [reader cancelReading];
                break;
            }
        }
        if (status == HWBPMAnalysisOK &&
            reader.status != AVAssetReaderStatusCompleted) {
            status = hw_bpm_cancellation_token_is_cancelled(cancellationToken) ?
                HWBPMAnalysisCancelled : HWBPMAnalysisUnreadable;
        }
        if (status == HWBPMAnalysisOK &&
            (analyzer.fluxCount == 0 || analyzer.samplesSinceLastFrame > 0)) {
            if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
                status = HWBPMAnalysisCancelled;
            } else {
                memset(
                    analyzer.frame + analyzer.frameFill,
                    0,
                    ((size_t)HW_BPM_FRAME_LENGTH - analyzer.frameFill) * sizeof(float));
                if (!hw_bpm_analyze_frame(&analyzer)) {
                    status = HWBPMAnalysisUnreadable;
                }
            }
        }
        if (status == HWBPMAnalysisOK && !hw_bpm_normalize_flux(&analyzer)) {
            status = HWBPMAnalysisUnreadable;
        }
        if (status == HWBPMAnalysisOK && hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
            status = HWBPMAnalysisCancelled;
        }
        if (status == HWBPMAnalysisOK) {
            *values = analyzer.flux;
            *count = analyzer.fluxCount;
            *rate_hz = HW_BPM_SAMPLE_RATE / (double)HW_BPM_HOP_LENGTH;
            analyzer.flux = NULL;
            analyzer.fluxCount = 0;
            analyzer.fluxCapacity = 0;
        }
        hw_bpm_analyzer_destroy(&analyzer);
        return status;
    }
}

void hw_bpm_free_onset_envelope(float *values) {
    free(values);
}

HWBPMAnalysisStatus hw_waveform_copy_peaks(
    const char *path,
    const HWBPMCancellationToken *cancellationToken,
    HWWaveformPeak **peaks,
    size_t *count,
    double *rateHz
) {
    if (peaks != NULL) {
        *peaks = NULL;
    }
    if (count != NULL) {
        *count = 0;
    }
    if (rateHz != NULL) {
        *rateHz = 0.0;
    }
    if (path == NULL || path[0] == '\0' || peaks == NULL || count == NULL ||
        rateHz == NULL) {
        return HWBPMAnalysisUnreadable;
    }
    if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
        return HWBPMAnalysisCancelled;
    }

    @autoreleasepool {
        NSString *filePath = [NSString stringWithUTF8String:path];
        if (filePath == nil ||
            ![[NSFileManager defaultManager] isReadableFileAtPath:filePath]) {
            return HWBPMAnalysisUnreadable;
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:
            [NSURL fileURLWithPath:filePath isDirectory:NO] options:nil];
        NSArray<AVAssetTrack *> *audioTracks = nil;
        HWBPMAnalysisStatus trackStatus = hw_bpm_wait_for_audio_tracks(
            asset,
            cancellationToken,
            &audioTracks);
        if (trackStatus != HWBPMAnalysisOK) {
            return trackStatus;
        }

        NSError *readerError = nil;
        AVAssetReader *reader = [[AVAssetReader alloc]
            initWithAsset:asset error:&readerError];
        if (reader == nil || readerError != nil) {
            return HWBPMAnalysisUnreadable;
        }
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(HW_BPM_SAMPLE_RATE),
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleavedKey: @NO,
        };
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:audioTracks.firstObject outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            return HWBPMAnalysisUnreadable;
        }
        [reader addOutput:output];
        if (![reader startReading]) {
            return HWBPMAnalysisUnreadable;
        }

        const size_t samplesPerPeak = HW_WAVEFORM_SAMPLES_PER_PEAK;
        HWWaveformPeak *result = NULL;
        size_t resultCount = 0;
        size_t resultCapacity = 0;
        size_t binFill = 0;
        HWWaveformPeak peak = hw_waveform_empty_peak();
        HWWaveformBiquad lowPass;
        HWWaveformBiquad midHighPass;
        HWWaveformBiquad midLowPass;
        HWWaveformBiquad highPass;
        hw_waveform_biquad_configure(
            &lowPass,
            HW_WAVEFORM_LOW_CUTOFF_HZ,
            false);
        hw_waveform_biquad_configure(
            &midHighPass,
            HW_WAVEFORM_LOW_CUTOFF_HZ,
            true);
        hw_waveform_biquad_configure(
            &midLowPass,
            HW_WAVEFORM_HIGH_CUTOFF_HZ,
            false);
        hw_waveform_biquad_configure(
            &highPass,
            HW_WAVEFORM_HIGH_CUTOFF_HZ,
            true);
        HWBPMAnalysisStatus status = HWBPMAnalysisOK;

        while (reader.status == AVAssetReaderStatusReading) {
            if (hw_bpm_cancellation_token_is_cancelled(cancellationToken)) {
                status = HWBPMAnalysisCancelled;
                [reader cancelReading];
                break;
            }
            CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
            if (sampleBuffer == NULL) {
                break;
            }
            CMBlockBufferRef retainedBlock = NULL;
            AudioBufferList bufferList;
            OSStatus bufferStatus =
                CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    NULL,
                    &bufferList,
                    sizeof(bufferList),
                    NULL,
                    NULL,
                    kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                    &retainedBlock);
            if (bufferStatus != noErr ||
                !hw_bpm_sample_buffer_is_expected_pcm(sampleBuffer, &bufferList)) {
                status = HWBPMAnalysisUnreadable;
            } else {
                size_t sampleCount =
                    bufferList.mBuffers[0].mDataByteSize / sizeof(float);
                const float *samples = bufferList.mBuffers[0].mData;
                for (size_t index = 0; index < sampleCount; index += 1) {
                    float sample = samples[index];
                    if (!isfinite(sample)) {
                        status = HWBPMAnalysisUnreadable;
                        break;
                    }
                    const float low = hw_waveform_biquad_process(
                        &lowPass,
                        sample);
                    const float mid = hw_waveform_biquad_process(
                        &midLowPass,
                        hw_waveform_biquad_process(&midHighPass, sample));
                    const float high = hw_waveform_biquad_process(
                        &highPass,
                        sample);
                    if (!isfinite(low) || !isfinite(mid) || !isfinite(high)) {
                        status = HWBPMAnalysisUnreadable;
                        break;
                    }
                    peak.low_minimum = fminf(peak.low_minimum, low);
                    peak.low_maximum = fmaxf(peak.low_maximum, low);
                    peak.mid_minimum = fminf(peak.mid_minimum, mid);
                    peak.mid_maximum = fmaxf(peak.mid_maximum, mid);
                    peak.high_minimum = fminf(peak.high_minimum, high);
                    peak.high_maximum = fmaxf(peak.high_maximum, high);
                    binFill += 1;
                    if (binFill != samplesPerPeak) {
                        continue;
                    }
                    if (!hw_waveform_reserve_peak(
                            &result,
                            resultCount,
                            &resultCapacity)) {
                        status = HWBPMAnalysisUnreadable;
                        break;
                    }
                    result[resultCount] = peak;
                    resultCount += 1;
                    binFill = 0;
                    peak = hw_waveform_empty_peak();
                }
            }
            if (retainedBlock != NULL) {
                CFRelease(retainedBlock);
            }
            CFRelease(sampleBuffer);
            if (status != HWBPMAnalysisOK) {
                [reader cancelReading];
                break;
            }
        }
        if (status == HWBPMAnalysisOK &&
            reader.status != AVAssetReaderStatusCompleted) {
            status = hw_bpm_cancellation_token_is_cancelled(cancellationToken) ?
                HWBPMAnalysisCancelled : HWBPMAnalysisUnreadable;
        }
        if (status == HWBPMAnalysisOK && binFill > 0) {
            if (!hw_waveform_reserve_peak(
                    &result,
                    resultCount,
                    &resultCapacity)) {
                status = HWBPMAnalysisUnreadable;
            } else {
                result[resultCount] = peak;
                resultCount += 1;
            }
        }
        if (status == HWBPMAnalysisOK && resultCount == 0) {
            status = HWBPMAnalysisUnreadable;
        }
        if (status == HWBPMAnalysisOK) {
            *peaks = result;
            *count = resultCount;
            *rateHz = HW_BPM_SAMPLE_RATE / (double)samplesPerPeak;
            result = NULL;
        }
        free(result);
        return status;
    }
}

void hw_waveform_free_peaks(HWWaveformPeak *peaks) {
    free(peaks);
}
