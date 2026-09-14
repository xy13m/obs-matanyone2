// SPDX-License-Identifier: GPL-3.0-or-later

#include <obs-module.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-matanyone2-matting", "en-US")

namespace {

constexpr const char *source_id = "matanyone2_matting";
constexpr const char *log_prefix = "[obs-matanyone2]";

struct filter_state {
    obs_source_t *source = nullptr;
};

const char *filter_name(void *) {
    return obs_module_text("MatAnyone2Matting");
}

void *filter_create(obs_data_t *, obs_source_t *source) {
    auto *state = new filter_state;
    state->source = source;
    return state;
}

void filter_destroy(void *data) {
    delete static_cast<filter_state *>(data);
}

// Bootstrap: the matting pipeline is not wired up yet, so the filter passes
// the source through untouched.
void filter_render(void *data, gs_effect_t *) {
    auto *state = static_cast<filter_state *>(data);
    obs_source_skip_video_filter(state->source);
}

obs_source_info filter_info = {
    .id = source_id,
    .type = OBS_SOURCE_TYPE_FILTER,
    .output_flags = OBS_SOURCE_VIDEO,
    .get_name = filter_name,
    .create = filter_create,
    .destroy = filter_destroy,
    .video_render = filter_render,
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
