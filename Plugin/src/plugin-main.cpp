// SPDX-License-Identifier: GPL-3.0-or-later

#include "render.hpp"

#include <MatAnyone2Bridge.h>
#include <obs-module.h>
#include <util/platform.h>

#include <cstring>
#include <memory>
#include <mutex>
#include <string>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-matanyone2-matting", "en-US")

namespace {

constexpr const char *source_id = "matanyone2_matting";
constexpr const char *log_prefix = "[obs-matanyone2]";

#define T(key) obs_module_text(key)

struct filter_state {
    obs_source_t *source = nullptr;
    ma2_context_t context = nullptr;
    ma2::renderer renderer;
    bool renderer_ready = false;

    std::mutex mutex;
    ma2::render_params params;
    int compute_units = MA2_COMPUTE_CPU_ANE;
    bool overlay_calibration = true;
    bool overlay_always = false;
    ma2_status status{};
    uint32_t last_status_version = 0;
    float tick_accumulator = 0.0f;
    std::string models_error;
    obs_hotkey_id hotkey_ids[5] = {OBS_INVALID_HOTKEY_ID, OBS_INVALID_HOTKEY_ID,
                                   OBS_INVALID_HOTKEY_ID, OBS_INVALID_HOTKEY_ID,
                                   OBS_INVALID_HOTKEY_ID};
};

void log_from_worker(void *, const char *message) {
    const bool warning = std::strncmp(message, "error:", 6) == 0;
    blog(warning ? LOG_WARNING : LOG_INFO, "%s %s", log_prefix, message);
}

int compute_units_from_string(const char *value) {
    if (std::strcmp(value, "cpu_gpu") == 0)
        return MA2_COMPUTE_CPU_GPU;
    if (std::strcmp(value, "all") == 0)
        return MA2_COMPUTE_ALL;
    return MA2_COMPUTE_CPU_ANE;
}

ma2::preview_mode preview_from_string(const char *value) {
    if (std::strcmp(value, "alpha") == 0)
        return ma2::preview_mode::alpha;
    if (std::strcmp(value, "checkerboard") == 0)
        return ma2::preview_mode::checkerboard;
    return ma2::preview_mode::off;
}

ma2::refinement_mode refinement_from_string(const char *value) {
    if (std::strcmp(value, "bilateral") == 0)
        return ma2::refinement_mode::bilateral;
    if (std::strcmp(value, "guided") == 0)
        return ma2::refinement_mode::guided;
    return ma2::refinement_mode::none;
}

// ---------------------------------------------------------------- settings

const char *filter_name(void *) {
    return T("MatAnyone2Matting");
}

void filter_defaults(obs_data_t *settings) {
    obs_data_set_default_string(settings, "status", "");
    obs_data_set_default_int(settings, "countdown_seconds", 3);
    obs_data_set_default_int(settings, "plate_frames", 16);
    obs_data_set_default_int(settings, "props_threshold", 16);
    obs_data_set_default_int(settings, "props_min_region", 64);
    obs_data_set_default_int(settings, "reseed_interval", 0);
    obs_data_set_default_string(settings, "edge_refinement", "none");
    obs_data_set_default_double(settings, "edge_offset", 0.0);
    obs_data_set_default_double(settings, "temporal_smoothing", 0.0);
    obs_data_set_default_string(settings, "alignment", "lowest_latency");
    obs_data_set_default_string(settings, "compute_units", "cpu_ane");
    obs_data_set_default_int(settings, "max_matte_fps", 0);
    obs_data_set_default_bool(settings, "gpu_downscale", true);
    obs_data_set_default_bool(settings, "speck_filter", true);
    obs_data_set_default_bool(settings, "overlay_calibration", true);
    obs_data_set_default_bool(settings, "overlay_always", false);
    obs_data_set_default_string(settings, "matte_preview", "off");
    obs_data_set_default_bool(settings, "verbose_logging", false);
}

void filter_update(void *data, obs_data_t *settings) {
    auto *state = static_cast<filter_state *>(data);
    if (!state)
        return;

    ma2_options options{};
    options.countdown_seconds =
        static_cast<int32_t>(obs_data_get_int(settings, "countdown_seconds"));
    options.plate_frames = static_cast<int32_t>(obs_data_get_int(settings, "plate_frames"));
    options.props_threshold = static_cast<int32_t>(obs_data_get_int(settings, "props_threshold"));
    options.props_min_region = static_cast<int32_t>(obs_data_get_int(settings, "props_min_region"));
    options.reseed_interval_seconds =
        static_cast<int32_t>(obs_data_get_int(settings, "reseed_interval"));
    options.max_matte_fps = static_cast<int32_t>(obs_data_get_int(settings, "max_matte_fps"));
    options.edge_offset_px = static_cast<float>(obs_data_get_double(settings, "edge_offset"));
    options.temporal_smoothing =
        static_cast<float>(obs_data_get_double(settings, "temporal_smoothing"));
    options.speck_filter = obs_data_get_bool(settings, "speck_filter");
    options.verbose_logging = obs_data_get_bool(settings, "verbose_logging");
    const int compute_units =
        compute_units_from_string(obs_data_get_string(settings, "compute_units"));

    ma2::render_params params;
    params.preview = preview_from_string(obs_data_get_string(settings, "matte_preview"));
    params.refinement = refinement_from_string(obs_data_get_string(settings, "edge_refinement"));
    params.alignment = std::strcmp(obs_data_get_string(settings, "alignment"), "aligned") == 0
                           ? ma2::alignment_mode::aligned
                           : ma2::alignment_mode::lowest_latency;
    params.gpu_downscale = obs_data_get_bool(settings, "gpu_downscale");

    bool units_changed = false;
    {
        std::lock_guard lock(state->mutex);
        state->params = params;
        state->overlay_calibration = obs_data_get_bool(settings, "overlay_calibration");
        state->overlay_always = obs_data_get_bool(settings, "overlay_always");
        units_changed = state->compute_units != compute_units;
        state->compute_units = compute_units;
    }
    if (state->context) {
        ma2_set_options(state->context, &options);
        if (units_changed)
            ma2_set_compute_units(state->context, compute_units);
    }
}

// ---------------------------------------------------------------- buttons

bool send_request(void *data, ma2_request_kind request) {
    auto *state = static_cast<filter_state *>(data);
    if (state && state->context)
        ma2_request(state->context, request);
    return false;
}

bool on_capture_clean(obs_properties_t *, obs_property_t *, void *data) {
    return send_request(data, MA2_REQUEST_CAPTURE_CLEAN);
}
bool on_capture_props(obs_properties_t *, obs_property_t *, void *data) {
    return send_request(data, MA2_REQUEST_CAPTURE_PROPS);
}
bool on_seed(obs_properties_t *, obs_property_t *, void *data) {
    return send_request(data, MA2_REQUEST_SEED);
}
bool on_reseed(obs_properties_t *, obs_property_t *, void *data) {
    return send_request(data, MA2_REQUEST_RESEED);
}
bool on_clear(obs_properties_t *, obs_property_t *, void *data) {
    return send_request(data, MA2_REQUEST_CLEAR);
}

// ---------------------------------------------------------------- hotkeys

struct hotkey_binding {
    const char *name;
    const char *description_key;
    ma2_request_kind request;
};

constexpr hotkey_binding hotkeys[] = {
    {"matanyone2.capture_clean_plate", "CaptureCleanPlate", MA2_REQUEST_CAPTURE_CLEAN},
    {"matanyone2.capture_props_plate", "CapturePropsPlate", MA2_REQUEST_CAPTURE_PROPS},
    {"matanyone2.seed_now", "SeedNow", MA2_REQUEST_SEED},
    {"matanyone2.reseed_now", "ReseedNow", MA2_REQUEST_RESEED},
    {"matanyone2.clear_calibration", "ClearCalibration", MA2_REQUEST_CLEAR},
};

template <size_t index> void on_hotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed) {
    if (pressed)
        send_request(data, hotkeys[index].request);
}

// The same actions as the buttons, so calibration can be driven from the
// keyboard or obs-websocket without opening the properties panel. Hotkeys
// belong to the parent source, so they are registered when the filter is
// attached and removed when it is detached. One filter per source.
void filter_add(void *data, obs_source_t *parent) {
    auto *state = static_cast<filter_state *>(data);
    if (!state || !parent)
        return;
    const obs_hotkey_func callbacks[] = {on_hotkey<0>, on_hotkey<1>, on_hotkey<2>, on_hotkey<3>,
                                         on_hotkey<4>};
    for (size_t i = 0; i < 5; i++) {
        if (state->hotkey_ids[i] == OBS_INVALID_HOTKEY_ID) {
            state->hotkey_ids[i] = obs_hotkey_register_source(
                parent, hotkeys[i].name, T(hotkeys[i].description_key), callbacks[i], state);
        }
    }
}

void filter_remove(void *data, obs_source_t *) {
    auto *state = static_cast<filter_state *>(data);
    if (!state)
        return;
    for (auto &id : state->hotkey_ids) {
        if (id != OBS_INVALID_HOTKEY_ID) {
            obs_hotkey_unregister(id);
            id = OBS_INVALID_HOTKEY_ID;
        }
    }
}

// ---------------------------------------------------------------- properties

void describe(obs_property_t *property, const char *key) {
    obs_property_set_long_description(property, T(key));
}

obs_properties_t *filter_properties(void *data) {
    auto *state = static_cast<filter_state *>(data);
    obs_properties_t *props = obs_properties_create();

    obs_property_t *status = obs_properties_add_text(props, "status", "", OBS_TEXT_INFO);
    obs_property_text_set_info_type(status, OBS_TEXT_INFO_NORMAL);
    if (state) {
        std::lock_guard lock(state->mutex);
        if (!state->models_error.empty() || state->status.phase == MA2_PHASE_ERROR)
            obs_property_text_set_info_type(status, OBS_TEXT_INFO_ERROR);
        else if (state->status.phase == MA2_PHASE_WAITING_FOR_PERSON)
            obs_property_text_set_info_type(status, OBS_TEXT_INFO_WARNING);
    }

    obs_properties_t *calibration = obs_properties_create();
    describe(obs_properties_add_button2(calibration, "capture_clean_plate", T("CaptureCleanPlate"),
                                        on_capture_clean, data),
             "CaptureCleanPlate.Description");
    describe(obs_properties_add_button2(calibration, "capture_props_plate", T("CapturePropsPlate"),
                                        on_capture_props, data),
             "CapturePropsPlate.Description");
    describe(obs_properties_add_button2(calibration, "seed_now", T("SeedNow"), on_seed, data),
             "SeedNow.Description");
    describe(obs_properties_add_button2(calibration, "reseed_now", T("ReseedNow"), on_reseed, data),
             "ReseedNow.Description");
    describe(obs_properties_add_button2(calibration, "clear_calibration", T("ClearCalibration"),
                                        on_clear, data),
             "ClearCalibration.Description");
    obs_property_t *p = obs_properties_add_int_slider(calibration, "countdown_seconds",
                                                      T("CountdownSeconds"), 1, 10, 1);
    obs_property_int_set_suffix(p, " s");
    describe(p, "CountdownSeconds.Description");
    p = obs_properties_add_int_slider(calibration, "plate_frames", T("PlateFrames"), 4, 64, 1);
    describe(p, "PlateFrames.Description");
    p = obs_properties_add_int_slider(calibration, "props_threshold", T("PropsThreshold"), 4, 64,
                                      1);
    describe(p, "PropsThreshold.Description");
    p = obs_properties_add_int_slider(calibration, "props_min_region", T("PropsMinRegion"), 8, 4000,
                                      1);
    obs_property_int_set_suffix(p, " px");
    describe(p, "PropsMinRegion.Description");
    p = obs_properties_add_int_slider(calibration, "reseed_interval", T("ReseedInterval"), 0, 600,
                                      1);
    obs_property_int_set_suffix(p, " s");
    describe(p, "ReseedInterval.Description");
    obs_properties_add_group(props, "calibration", T("Calibration"), OBS_GROUP_NORMAL, calibration);

    obs_properties_t *quality = obs_properties_create();
    p = obs_properties_add_list(quality, "edge_refinement", T("EdgeRefinement"),
                                OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(p, T("EdgeRefinement.None"), "none");
    obs_property_list_add_string(p, T("EdgeRefinement.Bilateral"), "bilateral");
    obs_property_list_add_string(p, T("EdgeRefinement.Guided"), "guided");
    describe(p, "EdgeRefinement.Description");
    p = obs_properties_add_float_slider(quality, "edge_offset", T("EdgeOffset"), -8.0, 8.0, 0.5);
    obs_property_float_set_suffix(p, " px");
    describe(p, "EdgeOffset.Description");
    p = obs_properties_add_float_slider(quality, "temporal_smoothing", T("TemporalSmoothing"), 0.0,
                                        0.9, 0.05);
    describe(p, "TemporalSmoothing.Description");
    p = obs_properties_add_list(quality, "alignment", T("Alignment"), OBS_COMBO_TYPE_LIST,
                                OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(p, T("Alignment.LowestLatency"), "lowest_latency");
    obs_property_list_add_string(p, T("Alignment.Aligned"), "aligned");
    describe(p, "Alignment.Description");
    obs_properties_add_group(props, "quality", T("OutputQuality"), OBS_GROUP_NORMAL, quality);

    obs_properties_t *performance = obs_properties_create();
    p = obs_properties_add_list(performance, "compute_units", T("ComputeUnits"),
                                OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(p, T("ComputeUnits.CpuAne"), "cpu_ane");
    obs_property_list_add_string(p, T("ComputeUnits.CpuGpu"), "cpu_gpu");
    obs_property_list_add_string(p, T("ComputeUnits.All"), "all");
    describe(p, "ComputeUnits.Description");
    p = obs_properties_add_int_slider(performance, "max_matte_fps", T("MaxMatteFps"), 0, 60, 1);
    obs_property_int_set_suffix(p, " fps");
    describe(p, "MaxMatteFps.Description");
    p = obs_properties_add_bool(performance, "gpu_downscale", T("GpuDownscale"));
    describe(p, "GpuDownscale.Description");
    p = obs_properties_add_bool(performance, "speck_filter", T("SpeckFilter"));
    describe(p, "SpeckFilter.Description");
    obs_properties_add_group(props, "performance", T("Performance"), OBS_GROUP_NORMAL, performance);

    obs_properties_t *diagnostics = obs_properties_create();
    p = obs_properties_add_bool(diagnostics, "overlay_calibration", T("OverlayCalibration"));
    describe(p, "OverlayCalibration.Description");
    p = obs_properties_add_bool(diagnostics, "overlay_always", T("OverlayAlways"));
    describe(p, "OverlayAlways.Description");
    p = obs_properties_add_list(diagnostics, "matte_preview", T("MattePreview"),
                                OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(p, T("MattePreview.Off"), "off");
    obs_property_list_add_string(p, T("MattePreview.Alpha"), "alpha");
    obs_property_list_add_string(p, T("MattePreview.Checkerboard"), "checkerboard");
    describe(p, "MattePreview.Description");
    p = obs_properties_add_bool(diagnostics, "verbose_logging", T("VerboseLogging"));
    describe(p, "VerboseLogging.Description");
    obs_properties_add_group(props, "diagnostics", T("Diagnostics"), OBS_GROUP_NORMAL, diagnostics);

    return props;
}

// ---------------------------------------------------------------- lifecycle

std::string calibration_directory(obs_source_t *source) {
    std::string relative = "calibration/";
    const char *uuid = obs_source_get_uuid(source);
    relative += uuid && *uuid ? uuid : "default";
    char *path = obs_module_config_path(relative.c_str());
    std::string result = path ? path : "";
    bfree(path);
    return result;
}

void *filter_create(obs_data_t *settings, obs_source_t *source) {
    auto *state = new filter_state;
    state->source = source;
    state->compute_units =
        compute_units_from_string(obs_data_get_string(settings, "compute_units"));

    char *models = obs_module_file("models/MatAnyone");
    const std::string calibration = calibration_directory(source);
    if (models) {
        ma2_create_options options{};
        options.models_directory = models;
        options.calibration_directory = calibration.c_str();
        options.plugin_version = PLUGIN_VERSION;
        options.compute_units = state->compute_units;
        state->context = ma2_create(&options, log_from_worker, state);
    }
    if (!state->context) {
        state->models_error = "MatAnyone 2 models are missing from the plugin bundle";
        blog(LOG_ERROR, "%s %s (%s)", log_prefix, state->models_error.c_str(),
             models ? models : "no models directory");
    } else {
        blog(LOG_INFO, "%s filter created, working resolution %dx%d, calibration in %s", log_prefix,
             ma2_working_width(state->context), ma2_working_height(state->context),
             calibration.c_str());
    }
    bfree(models);

    if (state->context) {
        obs_enter_graphics();
        state->renderer_ready =
            state->renderer.init(static_cast<uint32_t>(ma2_working_width(state->context)),
                                 static_cast<uint32_t>(ma2_working_height(state->context)));
        obs_leave_graphics();
    }
    filter_update(state, settings);
    return state;
}

void filter_destroy(void *data) {
    auto *state = static_cast<filter_state *>(data);
    if (!state)
        return;
    filter_remove(state, nullptr);
    ma2_destroy(state->context);
    state->context = nullptr;
    obs_enter_graphics();
    state->renderer.destroy();
    obs_leave_graphics();
    delete state;
}

// Polls the worker status a few times per second and pushes the text into the
// properties panel when it changed.
void filter_tick(void *data, float seconds) {
    auto *state = static_cast<filter_state *>(data);
    if (!state)
        return;
    state->tick_accumulator += seconds;
    const bool tracking = state->status.phase == MA2_PHASE_TRACKING;
    // Rebuilding the properties view interrupts slider drags, so refresh
    // slowly while tracking and quickly during the countdowns.
    const float interval = tracking ? 2.0f : 0.5f;
    if (state->tick_accumulator < interval)
        return;
    state->tick_accumulator = 0.0f;

    ma2_status status{};
    if (state->context) {
        ma2_get_status(state->context, &status);
    } else {
        status.phase = MA2_PHASE_ERROR;
        std::snprintf(status.panel_text, sizeof(status.panel_text), "Error: %s",
                      state->models_error.c_str());
        status.version = 1;
    }
    {
        std::lock_guard lock(state->mutex);
        state->status = status;
    }
    if (status.version == state->last_status_version)
        return;
    state->last_status_version = status.version;

    obs_data_t *settings = obs_source_get_settings(state->source);
    obs_data_set_string(settings, "status", status.panel_text);
    obs_data_release(settings);
    obs_source_update_properties(state->source);
}

void filter_render(void *data, gs_effect_t *) {
    auto *state = static_cast<filter_state *>(data);
    if (!state || !state->context || !state->renderer_ready) {
        if (state)
            obs_source_skip_video_filter(state->source);
        return;
    }

    ma2::render_params params;
    int32_t phase;
    {
        std::lock_guard lock(state->mutex);
        params = state->params;
        phase = state->status.phase;
    }

    const uint64_t now = os_gettime_ns();
    if (!state->renderer.capture(state->source, state->context, params, now)) {
        obs_source_skip_video_filter(state->source);
        return;
    }

    ma2_matte matte{};
    if (ma2_poll_matte(state->context, &matte))
        state->renderer.upload_matte(matte);
    // Keep showing the last matte through a re-seed; drop it once the worker
    // is no longer tracking at all.
    if (phase != MA2_PHASE_TRACKING && phase != MA2_PHASE_SEEDING && phase != MA2_PHASE_ERROR)
        state->renderer.clear_matte();

    state->renderer.draw(state->source, params);
}

obs_source_info filter_info = {
    .id = source_id,
    .type = OBS_SOURCE_TYPE_FILTER,
    .output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB,
    .get_name = filter_name,
    .create = filter_create,
    .destroy = filter_destroy,
    .get_defaults = filter_defaults,
    .get_properties = filter_properties,
    .update = filter_update,
    .video_tick = filter_tick,
    .video_render = filter_render,
    .filter_remove = filter_remove,
    .filter_add = filter_add,
};

} // namespace

extern "C" bool obs_module_load(void) {
    obs_register_source(&filter_info);
    blog(LOG_INFO, "%s plugin loaded (version %s)", log_prefix, PLUGIN_VERSION);
    return true;
}

extern "C" const char *obs_module_description(void) {
    return "MatAnyone 2 video matting for Apple Silicon";
}
