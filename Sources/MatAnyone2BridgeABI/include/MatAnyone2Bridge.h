// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef MATANYONE2_BRIDGE_H
#define MATANYONE2_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C ABI over the Swift matting worker. Every function returns without
 * blocking except ma2_destroy, which joins the worker thread. All functions
 * may be called from any thread. */

typedef void *ma2_context_t;

typedef void (*ma2_log_fn)(void *user, const char *message);

/* 0 = CPU + Neural Engine, 1 = CPU + GPU, 2 = all. */
enum ma2_compute_units {
    MA2_COMPUTE_CPU_ANE = 0,
    MA2_COMPUTE_CPU_GPU = 1,
    MA2_COMPUTE_ALL = 2,
};

typedef struct ma2_create_options {
    const char *models_directory;      /* manifest.json + six .mlmodelc */
    const char *calibration_directory; /* per-filter directory, created on save */
    const char *plugin_version;        /* recorded in calibration meta.json */
    int32_t compute_units;             /* enum ma2_compute_units */
} ma2_create_options;

typedef struct ma2_options {
    int32_t countdown_seconds;
    int32_t plate_frames;
    int32_t props_threshold;         /* 0-255 per-pixel difference */
    int32_t props_min_region;        /* working-resolution pixels */
    int32_t reseed_interval_seconds; /* 0 = off */
    int32_t max_matte_fps;           /* 0 = unlimited */
    float edge_offset_px;            /* negative erodes, positive feathers */
    float temporal_smoothing;        /* 0-0.9 weight of the previous matte */
    bool speck_filter;
    bool verbose_logging;
} ma2_options;

/* Parses manifest.json synchronously and starts loading the models on the
 * worker. Returns NULL only when the manifest is unreadable. The log callback
 * is invoked from the worker thread with messages without the log prefix. */
ma2_context_t ma2_create(const ma2_create_options *options, ma2_log_fn log, void *log_user);
void ma2_destroy(ma2_context_t context);

/* Working resolution from the manifest, valid right after ma2_create. */
int32_t ma2_working_width(ma2_context_t context);
int32_t ma2_working_height(ma2_context_t context);

void ma2_set_options(ma2_context_t context, const ma2_options *options);
/* Reloads the models on the worker; calibration is kept. */
void ma2_set_compute_units(ma2_context_t context, int32_t compute_units);

/* Copies one BGRA frame into the mailbox, replacing an unprocessed one. The
 * frame is usually at working resolution; a larger frame is downscaled on
 * the worker. Returns false when the frame was dropped. */
bool ma2_submit_frame(ma2_context_t context, const uint8_t *bgra, uint32_t stride, uint32_t width,
                      uint32_t height, uint64_t frame_id, uint64_t capture_ns);

typedef struct ma2_matte {
    const uint8_t *alpha; /* tightly packed width*height, valid until the next poll */
    uint32_t width;
    uint32_t height;
    uint64_t frame_id;
    uint64_t capture_ns;
    uint64_t ready_ns;
} ma2_matte;

/* True when a matte newer than the previous poll is available. */
bool ma2_poll_matte(ma2_context_t context, ma2_matte *out);

typedef enum ma2_request_kind {
    MA2_REQUEST_CAPTURE_CLEAN = 0,
    MA2_REQUEST_CAPTURE_PROPS = 1,
    MA2_REQUEST_SEED = 2,
    MA2_REQUEST_RESEED = 3,
    MA2_REQUEST_CLEAR = 4,
} ma2_request_kind;

void ma2_request(ma2_context_t context, ma2_request_kind request);

/* Phases match MatAnyone2Core.Phase raw values. */
typedef enum ma2_phase {
    MA2_PHASE_LOADING_MODELS = 0,
    MA2_PHASE_UNCALIBRATED = 1,
    MA2_PHASE_CAPTURING_CLEAN = 2,
    MA2_PHASE_CLEAN_CAPTURED = 3,
    MA2_PHASE_CAPTURING_PROPS = 4,
    MA2_PHASE_PROPS_CAPTURED = 5,
    MA2_PHASE_WAITING_FOR_PERSON = 6,
    MA2_PHASE_SEEDING = 7,
    MA2_PHASE_TRACKING = 8,
    MA2_PHASE_ERROR = 9,
} ma2_phase;

typedef struct ma2_status {
    uint32_t version; /* increments whenever any field changes */
    int32_t phase;    /* enum ma2_phase */
    float countdown_remaining_s;
    float matte_fps;
    float inference_ms_p50;
    float inference_ms_p95;
    float matte_age_ms;
    float aligned_latency_ms;
    uint32_t dropped_frames;
    uint32_t props_regions;
    uint32_t working_width;
    uint32_t working_height;
    bool calibrating;         /* true in the countdown and capture phases */
    char message[256];        /* last error or empty */
    char panel_text[512];     /* one line for the properties panel */
    char overlay_title[128];  /* overlay first line */
    char overlay_detail[256]; /* overlay second line */
} ma2_status;

void ma2_get_status(ma2_context_t context, ma2_status *out);

/* Capture-to-display latency measured by the renderer in aligned mode. */
void ma2_set_display_latency(ma2_context_t context, float milliseconds);

typedef struct ma2_overlay {
    const uint8_t *bgra; /* premultiplied, valid until the next poll */
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t version;
} ma2_overlay;

/* True when the overlay band changed since the previous poll. When
 * show_status_line is false the band is only produced during calibration,
 * seeding and errors. */
bool ma2_poll_overlay(ma2_context_t context, bool show_status_line, ma2_overlay *out);

#ifdef __cplusplus
}
#endif

#endif
