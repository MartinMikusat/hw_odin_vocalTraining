#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import <stdatomic.h>

enum {
    VT_PITCH_PERMISSION_UNKNOWN = 0,
    VT_PITCH_PERMISSION_DENIED = 1,
    VT_PITCH_PERMISSION_RESTRICTED = 2,
    VT_PITCH_PERMISSION_AUTHORIZED = 3,
};

enum {
    VT_PITCH_CAPTURE_STOPPED = 0,
    VT_PITCH_CAPTURE_RUNNING = 1,
    VT_PITCH_CAPTURE_NO_INPUT = 2,
    VT_PITCH_CAPTURE_START_FAILED = 3,
};

typedef struct {
    CFTypeRef engine;
    CFTypeRef input;
    os_unfair_lock lock;
    float *ring;
    uint32_t capacity;
    uint32_t readIndex;
    uint32_t writeIndex;
    uint32_t count;
    double sampleRate;
    int status;
} VTPitchCapture;

static _Atomic bool vt_pitch_permission_request_pending = false;

static AVAudioEngine *vt_pitch_engine(VTPitchCapture *capture) {
    return (__bridge AVAudioEngine *)capture->engine;
}

static AVAudioInputNode *vt_pitch_input(VTPitchCapture *capture) {
    return (__bridge AVAudioInputNode *)capture->input;
}

static void vt_pitch_capture_stop_internal(VTPitchCapture *capture) {
    if (capture == NULL) {
        return;
    }
    AVAudioInputNode *input = vt_pitch_input(capture);
    AVAudioEngine *engine = vt_pitch_engine(capture);
    if (input != nil) {
        [input removeTapOnBus:0];
    }
    if (engine != nil) {
        [engine stop];
    }
    if (capture->input != NULL) {
        CFBridgingRelease(capture->input);
        capture->input = NULL;
    }
    if (capture->engine != NULL) {
        CFBridgingRelease(capture->engine);
        capture->engine = NULL;
    }
    if (capture->status == VT_PITCH_CAPTURE_RUNNING) {
        capture->status = VT_PITCH_CAPTURE_STOPPED;
    }
}

int vt_pitch_permission_status(void) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized:
            return VT_PITCH_PERMISSION_AUTHORIZED;
        case AVAuthorizationStatusDenied:
            return VT_PITCH_PERMISSION_DENIED;
        case AVAuthorizationStatusRestricted:
            return VT_PITCH_PERMISSION_RESTRICTED;
        case AVAuthorizationStatusNotDetermined:
        default:
            return VT_PITCH_PERMISSION_UNKNOWN;
    }
}

bool vt_pitch_request_permission(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(
            &vt_pitch_permission_request_pending,
            &expected,
            true)) {
        return false;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                            completionHandler:^(BOOL granted) {
        (void)granted;
        atomic_store(&vt_pitch_permission_request_pending, false);
    }];
    return true;
}

bool vt_pitch_permission_request_active(void) {
    return atomic_load(&vt_pitch_permission_request_pending);
}

void *vt_pitch_capture_create(void) {
    VTPitchCapture *capture = calloc(1, sizeof(VTPitchCapture));
    if (capture == NULL) {
        return NULL;
    }
    capture->capacity = 65536;
    capture->ring = calloc(capture->capacity, sizeof(float));
    if (capture->ring == NULL) {
        free(capture);
        return NULL;
    }
    capture->lock = OS_UNFAIR_LOCK_INIT;
    capture->status = VT_PITCH_CAPTURE_STOPPED;
    return capture;
}

bool vt_pitch_capture_start(void *opaque) {
    VTPitchCapture *capture = opaque;
    if (capture == NULL) {
        return false;
    }
    if (capture->status == VT_PITCH_CAPTURE_RUNNING) {
        return true;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (input == nil || format.channelCount == 0 || format.sampleRate <= 0) {
        capture->status = VT_PITCH_CAPTURE_NO_INPUT;
        return false;
    }
    capture->engine = CFBridgingRetain(engine);
    capture->input = CFBridgingRetain(input);

    os_unfair_lock_lock(&capture->lock);
    capture->readIndex = 0;
    capture->writeIndex = 0;
    capture->count = 0;
    capture->sampleRate = format.sampleRate;
    os_unfair_lock_unlock(&capture->lock);

    [input installTapOnBus:0
                bufferSize:1024
                     format:format
                      block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        float *samples = buffer.floatChannelData == NULL
            ? NULL
            : buffer.floatChannelData[0];
        uint32_t length = buffer.frameLength;
        if (samples == NULL || length == 0) {
            return;
        }

        os_unfair_lock_lock(&capture->lock);
        capture->sampleRate = buffer.format.sampleRate;
        for (uint32_t index = 0; index < length; index += 1) {
            capture->ring[capture->writeIndex] = samples[index];
            capture->writeIndex =
                (capture->writeIndex + 1) % capture->capacity;
            if (capture->count == capture->capacity) {
                capture->readIndex =
                    (capture->readIndex + 1) % capture->capacity;
            } else {
                capture->count += 1;
            }
        }
        os_unfair_lock_unlock(&capture->lock);
    }];

    [engine prepare];
    NSError *error = nil;
    if (![engine startAndReturnError:&error]) {
        vt_pitch_capture_stop_internal(capture);
        capture->status = VT_PITCH_CAPTURE_START_FAILED;
        return false;
    }
    capture->status = VT_PITCH_CAPTURE_RUNNING;
    return true;
}

void vt_pitch_capture_stop(void *opaque) {
    vt_pitch_capture_stop_internal(opaque);
}

void vt_pitch_capture_destroy(void *opaque) {
    VTPitchCapture *capture = opaque;
    if (capture == NULL) {
        return;
    }
    vt_pitch_capture_stop_internal(capture);
    free(capture->ring);
    free(capture);
}

uint32_t vt_pitch_capture_read(
    void *opaque,
    float *destination,
    uint32_t capacity,
    double *sampleRate
) {
    VTPitchCapture *capture = opaque;
    if (capture == NULL || destination == NULL || capacity == 0) {
        return 0;
    }

    os_unfair_lock_lock(&capture->lock);
    uint32_t length = MIN(capacity, capture->count);
    if (sampleRate != NULL) {
        *sampleRate = capture->sampleRate;
    }
    for (uint32_t index = 0; index < length; index += 1) {
        destination[index] = capture->ring[capture->readIndex];
        capture->readIndex =
            (capture->readIndex + 1) % capture->capacity;
    }
    capture->count -= length;
    os_unfair_lock_unlock(&capture->lock);
    return length;
}

int vt_pitch_capture_status(void *opaque) {
    VTPitchCapture *capture = opaque;
    if (capture == NULL) {
        return VT_PITCH_CAPTURE_STOPPED;
    }
    return capture->status;
}
