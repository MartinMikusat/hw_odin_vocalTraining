#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/signpost.h>
#import <time.h>

typedef void (*HWVideoClipsPerfCallback)(uint64_t, int64_t, int64_t, int64_t);

static os_log_t hw_video_clips_perf_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.halwayland.hw-video-clips", "performance");
    });
    return log;
}

static int64_t hw_video_clips_perf_now_ns(void) {
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) {
        return 0;
    }
    return (int64_t)value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
}

void hw_video_clips_perf_signpost_begin(
    uint64_t identifier,
    const char *name,
    intptr_t length
) {
    os_signpost_interval_begin(
        hw_video_clips_perf_log(),
        (os_signpost_id_t)identifier,
        "Odin zone",
        "%{public}.*s",
        (int)length,
        name
    );
}

void hw_video_clips_perf_signpost_end(uint64_t identifier) {
    os_signpost_interval_end(
        hw_video_clips_perf_log(),
        (os_signpost_id_t)identifier,
        "Odin zone",
        "end"
    );
}

void hw_video_clips_perf_track_command_buffer(
    id<MTLCommandBuffer> command_buffer,
    uint64_t sequence,
    HWVideoClipsPerfCallback callback
) {
    if (command_buffer == nil || callback == NULL || sequence == 0) {
        return;
    }
    __block int64_t scheduled_ns = 0;
    [command_buffer addScheduledHandler:^(__unused id<MTLCommandBuffer> buffer) {
        scheduled_ns = hw_video_clips_perf_now_ns();
    }];
    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        const int64_t completed_ns = hw_video_clips_perf_now_ns();
        const double measured_gpu_seconds = buffer.GPUEndTime - buffer.GPUStartTime;
        const double gpu_seconds = measured_gpu_seconds > 0.0 ? measured_gpu_seconds : 0.0;
        callback(
            sequence,
            scheduled_ns,
            completed_ns,
            (int64_t)(gpu_seconds * 1000000000.0)
        );
    }];
}
