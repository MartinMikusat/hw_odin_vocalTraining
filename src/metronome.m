#import "metronome.h"

#import <AVFoundation/AVFoundation.h>

#include <math.h>
#include <mach/mach_time.h>
#include <stdlib.h>

struct HWMetronome {
    AVAudioPlayerNode *player;
    AVAudioPCMBuffer *accent;
    AVAudioPCMBuffer *regular;
    uint64_t anchorHostTime;
    double sampleRate;
};

static AVAudioPCMBuffer *hw_click_buffer(
    AVAudioFormat *format,
    double frequency,
    double amplitude
) {
    double sampleRate = format.sampleRate;
    AVAudioFrameCount frames = (AVAudioFrameCount)llround(sampleRate * 0.032);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:format frameCapacity:frames];
    if (buffer == nil || buffer.floatChannelData == NULL) {
        return nil;
    }
    buffer.frameLength = frames;
    float *samples = buffer.floatChannelData[0];
    for (AVAudioFrameCount index = 0; index < frames; index += 1) {
        double position = (double)index / (double)frames;
		double attack = fmin(1.0, (double)index / 12.0);
		double envelope = attack * exp(-5.0 * position);
        samples[index] = (float)(amplitude * envelope *
            sin(2.0 * M_PI * frequency * (double)index / sampleRate));
    }
    return buffer;
}

uint64_t hw_host_time_now(void) {
    return mach_absolute_time();
}

uint64_t hw_host_time_after_seconds(uint64_t hostTime, double seconds) {
    if (!isfinite(seconds) || seconds <= 0.0) {
        return hostTime;
    }
    return hostTime + [AVAudioTime hostTimeForSeconds:seconds];
}

uint64_t hw_host_time_before_seconds(uint64_t hostTime, double seconds) {
    if (!isfinite(seconds) || seconds <= 0.0) {
        return hostTime;
    }
    uint64_t delta = [AVAudioTime hostTimeForSeconds:seconds];
    return delta < hostTime ? hostTime - delta : 1;
}

HWMetronome *hw_metronome_create(void *engineValue, void *mixerValue) {
    AVAudioEngine *engine = (__bridge AVAudioEngine *)engineValue;
    AVAudioMixerNode *mixer = (__bridge AVAudioMixerNode *)mixerValue;
    if (engine == nil || mixer == nil) {
        return NULL;
    }
    HWMetronome *metronome = calloc(1, sizeof(*metronome));
    if (metronome == NULL) {
        return NULL;
    }
    metronome->player = [[AVAudioPlayerNode alloc] init];
    AVAudioFormat *mixerFormat = [mixer outputFormatForBus:0];
    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:mixerFormat.sampleRate channels:1];
    metronome->accent = hw_click_buffer(format, 1760.0, 0.98);
    metronome->regular = hw_click_buffer(format, 1100.0, 0.88);
    metronome->sampleRate = format.sampleRate;
    if (metronome->player == nil || metronome->accent == nil ||
        metronome->regular == nil) {
        metronome->player = nil;
        metronome->accent = nil;
        metronome->regular = nil;
        free(metronome);
        return NULL;
    }
    [engine attachNode:metronome->player];
    [engine connect:metronome->player to:mixer format:format];
    return metronome;
}

void hw_metronome_destroy(HWMetronome *metronome, void *engineValue) {
    if (metronome == NULL) {
        return;
    }
    AVAudioEngine *engine = (__bridge AVAudioEngine *)engineValue;
    [metronome->player stop];
    if (engine != nil) {
        [engine detachNode:metronome->player];
    }
    metronome->player = nil;
    metronome->accent = nil;
    metronome->regular = nil;
    free(metronome);
}

void hw_metronome_stop(HWMetronome *metronome) {
    if (metronome != NULL) {
        [metronome->player stop];
        metronome->anchorHostTime = 0;
    }
}

void hw_metronome_set_volume(HWMetronome *metronome, float volume) {
    if (metronome != NULL) {
        metronome->player.volume = fmaxf(0.0f, fminf(volume, 1.0f));
    }
}

bool hw_metronome_schedule(
    HWMetronome *metronome,
    uint64_t hostTime,
    bool accent
) {
    if (metronome == NULL || hostTime == 0) {
        return false;
    }
    if (metronome->anchorHostTime == 0) {
        metronome->anchorHostTime = hostTime;
    }
    if (hostTime < metronome->anchorHostTime) {
        return false;
    }
    uint64_t delta = hostTime - metronome->anchorHostTime;
    double seconds = [AVAudioTime secondsForHostTime:delta];
    AVAudioFramePosition sampleTime = (AVAudioFramePosition)llround(
        seconds * metronome->sampleRate);
    AVAudioTime *time = [AVAudioTime
        timeWithSampleTime:sampleTime
        atRate:metronome->sampleRate];
    [metronome->player scheduleBuffer:
        accent ? metronome->accent : metronome->regular
        atTime:time
        options:0
        completionHandler:nil];
    return true;
}

void hw_metronome_play(HWMetronome *metronome) {
    if (metronome != NULL && !metronome->player.isPlaying) {
        if (metronome->anchorHostTime == 0) {
            [metronome->player play];
        } else {
            [metronome->player playAtTime:
                [AVAudioTime timeWithHostTime:metronome->anchorHostTime]];
        }
    }
}

bool hw_audio_player_play_at_host_time(void *playerValue, uint64_t hostTime) {
    AVAudioPlayerNode *player = (__bridge AVAudioPlayerNode *)playerValue;
    if (player == nil || hostTime == 0) {
        return false;
    }
    [player playAtTime:[AVAudioTime timeWithHostTime:hostTime]];
    return true;
}
