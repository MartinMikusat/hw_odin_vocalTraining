#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <os/lock.h>
#import <stdatomic.h>

enum {
    HW_VIDEO_CLIPS_PITCH_PERMISSION_UNKNOWN = 0,
    HW_VIDEO_CLIPS_PITCH_PERMISSION_DENIED = 1,
    HW_VIDEO_CLIPS_PITCH_PERMISSION_RESTRICTED = 2,
    HW_VIDEO_CLIPS_PITCH_PERMISSION_AUTHORIZED = 3,
};

enum {
    HW_VIDEO_CLIPS_PITCH_CAPTURE_STOPPED = 0,
    HW_VIDEO_CLIPS_PITCH_CAPTURE_RUNNING = 1,
    HW_VIDEO_CLIPS_PITCH_CAPTURE_NO_INPUT = 2,
    HW_VIDEO_CLIPS_PITCH_CAPTURE_START_FAILED = 3,
};

enum {
    HW_VIDEO_CLIPS_PITCH_CAPTURE_BUFFER_COUNT = 3,
    HW_VIDEO_CLIPS_PITCH_CAPTURE_FRAMES_PER_BUFFER = 1024,
};

typedef struct {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[HW_VIDEO_CLIPS_PITCH_CAPTURE_BUFFER_COUNT];
    os_unfair_lock lock;
    float *ring;
    uint32_t capacity;
    uint32_t readIndex;
    uint32_t writeIndex;
    uint32_t count;
    double sampleRate;
    _Atomic int status;
} HWVideoClipsPitchCapture;

static _Atomic bool hw_video_clips_pitch_permission_request_pending = false;

static AudioDeviceID hw_video_clips_pitch_default_input_device(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus result = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size,
        &device);
    if (result != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static UInt32 hw_video_clips_pitch_device_transport(
    AudioDeviceID device
) {
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (AudioObjectGetPropertyData(
            device,
            &address,
            0,
            NULL,
            &size,
            &transport) != noErr) {
        return 0;
    }
    return transport;
}

static bool hw_video_clips_pitch_device_has_input(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(
        device,
        &address,
        0,
        NULL,
        &size) == noErr && size > 0;
}

static AudioDeviceID hw_video_clips_pitch_builtin_input_device(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject,
            &address,
            0,
            NULL,
            &size) != noErr || size == 0) {
        return kAudioObjectUnknown;
    }
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) {
        return kAudioObjectUnknown;
    }
    OSStatus result = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size,
        devices);
    AudioDeviceID selected = kAudioObjectUnknown;
    if (result == noErr) {
        uint32_t count = size / sizeof(AudioDeviceID);
        for (uint32_t index = 0; index < count; index += 1) {
            AudioDeviceID device = devices[index];
            if (hw_video_clips_pitch_device_transport(device) ==
                    kAudioDeviceTransportTypeBuiltIn &&
                hw_video_clips_pitch_device_has_input(device)) {
                selected = device;
                break;
            }
        }
    }
    free(devices);
    return selected;
}

static AudioDeviceID hw_video_clips_pitch_capture_input_device(void) {
    AudioDeviceID device = hw_video_clips_pitch_default_input_device();
    UInt32 transport = hw_video_clips_pitch_device_transport(device);
    if (transport == kAudioDeviceTransportTypeBluetooth ||
        transport == kAudioDeviceTransportTypeBluetoothLE) {
        AudioDeviceID builtin = hw_video_clips_pitch_builtin_input_device();
        if (builtin != kAudioObjectUnknown) {
            return builtin;
        }
    }
    return device;
}

static bool hw_video_clips_pitch_set_queue_device(
    AudioQueueRef queue,
    AudioDeviceID device
) {
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus result = AudioObjectGetPropertyData(
        device,
        &address,
        0,
        NULL,
        &size,
        &uid);
    if (result != noErr || uid == NULL) {
        return false;
    }
    result = AudioQueueSetProperty(
        queue,
        kAudioQueueProperty_CurrentDevice,
        &uid,
        sizeof(uid));
    CFRelease(uid);
    return result == noErr;
}

static void hw_video_clips_pitch_capture_samples(
    HWVideoClipsPitchCapture *capture,
    const float *samples,
    uint32_t length
) {
    if (capture == NULL || samples == NULL || length == 0) {
        return;
    }
    os_unfair_lock_lock(&capture->lock);
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
}

static void hw_video_clips_pitch_capture_callback(
    void *context,
    AudioQueueRef queue,
    AudioQueueBufferRef buffer,
    const AudioTimeStamp *startTime,
    UInt32 packetCount,
    const AudioStreamPacketDescription *packetDescriptions
) {
    (void)startTime;
    (void)packetCount;
    (void)packetDescriptions;
    HWVideoClipsPitchCapture *capture = context;
    if (capture == NULL ||
        atomic_load(&capture->status) != HW_VIDEO_CLIPS_PITCH_CAPTURE_RUNNING) {
        return;
    }

    uint32_t length = buffer->mAudioDataByteSize / sizeof(float);
    hw_video_clips_pitch_capture_samples(capture, buffer->mAudioData, length);

    if (atomic_load(&capture->status) == HW_VIDEO_CLIPS_PITCH_CAPTURE_RUNNING) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
}

static void hw_video_clips_pitch_capture_stop_internal(HWVideoClipsPitchCapture *capture) {
    if (capture == NULL) {
        return;
    }
    atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_STOPPED);
    if (capture->queue != NULL) {
        AudioQueueStop(capture->queue, true);
        AudioQueueDispose(capture->queue, true);
        capture->queue = NULL;
        for (uint32_t index = 0;
             index < HW_VIDEO_CLIPS_PITCH_CAPTURE_BUFFER_COUNT;
             index += 1) {
            capture->buffers[index] = NULL;
        }
    }
}

int hw_video_clips_pitch_permission_status(void) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized:
            return HW_VIDEO_CLIPS_PITCH_PERMISSION_AUTHORIZED;
        case AVAuthorizationStatusDenied:
            return HW_VIDEO_CLIPS_PITCH_PERMISSION_DENIED;
        case AVAuthorizationStatusRestricted:
            return HW_VIDEO_CLIPS_PITCH_PERMISSION_RESTRICTED;
        case AVAuthorizationStatusNotDetermined:
        default:
            return HW_VIDEO_CLIPS_PITCH_PERMISSION_UNKNOWN;
    }
}

bool hw_video_clips_pitch_request_permission(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(
            &hw_video_clips_pitch_permission_request_pending,
            &expected,
            true)) {
        return false;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                            completionHandler:^(BOOL granted) {
        (void)granted;
        atomic_store(&hw_video_clips_pitch_permission_request_pending, false);
    }];
    return true;
}

bool hw_video_clips_pitch_permission_request_active(void) {
    return atomic_load(&hw_video_clips_pitch_permission_request_pending);
}

void *hw_video_clips_pitch_capture_create(void) {
    HWVideoClipsPitchCapture *capture = calloc(1, sizeof(HWVideoClipsPitchCapture));
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
    atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_STOPPED);
    return capture;
}

bool hw_video_clips_pitch_capture_start(void *opaque) {
    HWVideoClipsPitchCapture *capture = opaque;
    if (capture == NULL) {
        return false;
    }
    if (atomic_load(&capture->status) == HW_VIDEO_CLIPS_PITCH_CAPTURE_RUNNING) {
        return true;
    }
    AudioDeviceID inputDevice = hw_video_clips_pitch_capture_input_device();
    if (inputDevice == kAudioObjectUnknown) {
        atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_NO_INPUT);
        return false;
    }

    AudioStreamBasicDescription format = {
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags =
            kAudioFormatFlagIsFloat |
            kAudioFormatFlagIsPacked |
            kAudioFormatFlagsNativeEndian,
        .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = sizeof(float) * 8,
    };
    OSStatus result = AudioQueueNewInput(
        &format,
        hw_video_clips_pitch_capture_callback,
        capture,
        NULL,
        NULL,
        0,
        &capture->queue);
    if (result != noErr || capture->queue == NULL) {
        capture->queue = NULL;
        atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_START_FAILED);
        return false;
    }
    if (!hw_video_clips_pitch_set_queue_device(capture->queue, inputDevice)) {
        AudioQueueDispose(capture->queue, true);
        capture->queue = NULL;
        atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_START_FAILED);
        return false;
    }

    os_unfair_lock_lock(&capture->lock);
    capture->readIndex = 0;
    capture->writeIndex = 0;
    capture->count = 0;
    capture->sampleRate = format.mSampleRate;
    os_unfair_lock_unlock(&capture->lock);

    UInt32 bufferSize =
        HW_VIDEO_CLIPS_PITCH_CAPTURE_FRAMES_PER_BUFFER * format.mBytesPerFrame;
    for (uint32_t index = 0;
         index < HW_VIDEO_CLIPS_PITCH_CAPTURE_BUFFER_COUNT;
         index += 1) {
        result = AudioQueueAllocateBuffer(
            capture->queue,
            bufferSize,
            &capture->buffers[index]);
        if (result == noErr) {
            result = AudioQueueEnqueueBuffer(
                capture->queue,
                capture->buffers[index],
                0,
                NULL);
        }
        if (result != noErr) {
            AudioQueueDispose(capture->queue, true);
            capture->queue = NULL;
            atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_START_FAILED);
            return false;
        }
    }

    atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_RUNNING);
    result = AudioQueueStart(capture->queue, NULL);
    if (result != noErr) {
        atomic_store(&capture->status, HW_VIDEO_CLIPS_PITCH_CAPTURE_START_FAILED);
        AudioQueueDispose(capture->queue, true);
        capture->queue = NULL;
        return false;
    }
    return true;
}

void hw_video_clips_pitch_capture_stop(void *opaque) {
    hw_video_clips_pitch_capture_stop_internal(opaque);
}

void hw_video_clips_pitch_capture_destroy(void *opaque) {
    HWVideoClipsPitchCapture *capture = opaque;
    if (capture == NULL) {
        return;
    }
    hw_video_clips_pitch_capture_stop_internal(capture);
    free(capture->ring);
    free(capture);
}

uint32_t hw_video_clips_pitch_capture_read(
    void *opaque,
    float *destination,
    uint32_t capacity,
    double *sampleRate
) {
    HWVideoClipsPitchCapture *capture = opaque;
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

int hw_video_clips_pitch_capture_status(void *opaque) {
    HWVideoClipsPitchCapture *capture = opaque;
    if (capture == NULL) {
        return HW_VIDEO_CLIPS_PITCH_CAPTURE_STOPPED;
    }
    return atomic_load(&capture->status);
}
