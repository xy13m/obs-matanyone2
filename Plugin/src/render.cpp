// SPDX-License-Identifier: GPL-3.0-or-later

#include "render.hpp"

#include <util/platform.h>

namespace ma2 {

namespace {

gs_effect_t *load_effect(const char *name) {
    char *path = obs_module_file(name);
    if (!path) {
        blog(LOG_ERROR, "[obs-matanyone2] effect %s not found in the bundle", name);
        return nullptr;
    }
    char *error = nullptr;
    gs_effect_t *effect = gs_effect_create_from_file(path, &error);
    if (!effect) {
        blog(LOG_ERROR, "[obs-matanyone2] failed to load %s: %s", name, error ? error : "unknown");
    }
    bfree(error);
    bfree(path);
    return effect;
}

} // namespace

renderer::~renderer() {
    destroy();
}

bool renderer::init(uint32_t working_width, uint32_t working_height) {
    destroy();
    working_width_ = working_width;
    working_height_ = working_height;
    downscale_effect_ = load_effect("effects/downscale.effect");
    composite_effect_ = load_effect("effects/matanyone2.effect");
    guided_effect_ = load_effect("effects/guided.effect");
    // BGRA so both staging paths hand the worker the byte order it expects.
    full_ = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
    work_ = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
    matte_ = gs_texture_create(working_width, working_height, GS_R8, 1, nullptr, GS_DYNAMIC);
    for (auto &slot : stages_) {
        slot.surface = gs_stagesurface_create(working_width, working_height, GS_BGRA);
        slot.valid = false;
    }
    const bool ok = downscale_effect_ && composite_effect_ && guided_effect_ && full_ && work_ &&
                    matte_ && stages_[0].surface && stages_[1].surface && stages_[2].surface;
    if (!ok) {
        blog(LOG_ERROR, "[obs-matanyone2] failed to create GPU resources");
        destroy();
    }
    return ok;
}

void renderer::destroy() {
    for (auto &slot : stages_) {
        gs_stagesurface_destroy(slot.surface);
        slot.surface = nullptr;
        slot.valid = false;
    }
    gs_stagesurface_destroy(full_stage_);
    full_stage_ = nullptr;
    gs_texture_destroy(matte_);
    matte_ = nullptr;
    gs_texture_destroy(overlay_);
    overlay_ = nullptr;
    for (auto &texrender : ring_) {
        gs_texrender_destroy(texrender);
        texrender = nullptr;
    }
    ring_ids_.clear();
    current_ = nullptr;
    gs_texrender_destroy(work_);
    work_ = nullptr;
    gs_texrender_destroy(full_);
    full_ = nullptr;
    gs_effect_destroy(composite_effect_);
    composite_effect_ = nullptr;
    gs_effect_destroy(downscale_effect_);
    downscale_effect_ = nullptr;
    gs_effect_destroy(guided_effect_);
    guided_effect_ = nullptr;
    for (gs_texrender_t **texrender :
         {&guided_pack_, &guided_blur_a_, &guided_blur_b_, &guided_coeff_}) {
        gs_texrender_destroy(*texrender);
        *texrender = nullptr;
    }
    has_matte_ = false;
    frame_width_ = 0;
    frame_height_ = 0;
}

bool renderer::capture(obs_source_t *filter, ma2_context_t context, const render_params &params,
                       uint64_t now_ns) {
    if (!full_)
        return false;
    // OBS renders a filter once per view (program, preview, projector). Only
    // the first render of a video frame captures and submits; later ones
    // reuse the textures.
    const uint64_t frame_time = obs_get_video_frame_time();
    if (frame_time == last_frame_time_ && current_)
        return true;
    last_frame_time_ = frame_time;

    frame_id_++;
    gs_texrender_t *into = full_;
    if (params.alignment == alignment_mode::aligned) {
        into = ring_texrender(ring_ids_.push(frame_id_, now_ns));
        if (!into)
            into = full_;
    }
    if (!render_target(filter, into)) {
        current_ = nullptr;
        return false;
    }
    current_ = into;
    gs_texture_t *source = gs_texrender_get_texture(current_);
    if (params.gpu_downscale) {
        downscale(source);
        stage_and_submit(context, now_ns);
    } else {
        submit_full_resolution(context, now_ns);
    }
    return true;
}

gs_texrender_t *renderer::ring_texrender(size_t slot) {
    if (!ring_[slot])
        ring_[slot] = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
    return ring_[slot];
}

// Same setup libobs uses in obs_source_process_filter_begin for an async
// parent: premultiplied blending, cleared target, orthographic projection.
bool renderer::render_target(obs_source_t *filter, gs_texrender_t *into) {
    obs_source_t *target = obs_filter_get_target(filter);
    if (!target)
        return false;
    const uint32_t width = obs_source_get_base_width(target);
    const uint32_t height = obs_source_get_base_height(target);
    if (!width || !height)
        return false;
    frame_width_ = width;
    frame_height_ = height;

    gs_texrender_reset(into);
    if (!gs_texrender_begin(into, width, height))
        return false;
    gs_blend_state_push();
    gs_blend_function_separate(GS_BLEND_SRCALPHA, GS_BLEND_INVSRCALPHA, GS_BLEND_ONE,
                               GS_BLEND_INVSRCALPHA);
    vec4 clear_color{};
    gs_clear(GS_CLEAR_COLOR, &clear_color, 0.0f, 0);
    gs_ortho(0.0f, static_cast<float>(width), 0.0f, static_cast<float>(height), -100.0f, 100.0f);
    obs_source_video_render(target);
    gs_blend_state_pop();
    gs_texrender_end(into);
    return true;
}

void renderer::downscale(gs_texture_t *source) {
    if (!source)
        return;
    gs_texrender_reset(work_);
    if (!gs_texrender_begin(work_, working_width_, working_height_))
        return;
    // Stage the bytes as stored, without sRGB decoding: the model was trained
    // on ordinary camera pixels.
    const bool previous_srgb = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(false);
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
    gs_ortho(0.0f, static_cast<float>(working_width_), 0.0f, static_cast<float>(working_height_),
             -100.0f, 100.0f);

    gs_effect_set_texture(gs_effect_get_param_by_name(downscale_effect_, "image"), source);
    vec2 texel_size;
    vec2_set(&texel_size, 1.0f / static_cast<float>(frame_width_),
             1.0f / static_cast<float>(frame_height_));
    gs_effect_set_vec2(gs_effect_get_param_by_name(downscale_effect_, "texel_size"), &texel_size);
    vec2 scale;
    vec2_set(&scale, static_cast<float>(frame_width_) / static_cast<float>(working_width_),
             static_cast<float>(frame_height_) / static_cast<float>(working_height_));
    gs_effect_set_vec2(gs_effect_get_param_by_name(downscale_effect_, "scale"), &scale);
    while (gs_effect_loop(downscale_effect_, "Draw"))
        gs_draw_sprite(source, 0, working_width_, working_height_);

    gs_blend_state_pop();
    gs_enable_framebuffer_srgb(previous_srgb);
    gs_texrender_end(work_);
}

void renderer::stage_and_submit(ma2_context_t context, uint64_t now_ns) {
    gs_texture_t *texture = gs_texrender_get_texture(work_);
    if (!texture)
        return;
    stage_slot &current = stages_[stage_index_];
    gs_stage_texture(current.surface, texture);
    current.frame_id = frame_id_;
    current.capture_ns = now_ns;
    current.valid = true;

    // Map the surface staged two frames ago.
    stage_index_ = (stage_index_ + 1) % stages_.size();
    stage_slot &oldest = stages_[stage_index_];
    if (!oldest.valid || !context)
        return;
    uint8_t *data = nullptr;
    uint32_t linesize = 0;
    if (gs_stagesurface_map(oldest.surface, &data, &linesize)) {
        ma2_submit_frame(context, data, linesize, working_width_, working_height_, oldest.frame_id,
                         oldest.capture_ns);
        gs_stagesurface_unmap(oldest.surface);
    }
    oldest.valid = false;
}

// Comparison and fallback path: stages the full frame and lets the worker
// downscale on the CPU. Maps immediately, so it stalls; that is the point of
// measuring it.
void renderer::submit_full_resolution(ma2_context_t context, uint64_t now_ns) {
    gs_texture_t *texture = current_ ? gs_texrender_get_texture(current_) : nullptr;
    if (!texture || !context)
        return;
    if (full_stage_ && (gs_stagesurface_get_width(full_stage_) != frame_width_ ||
                        gs_stagesurface_get_height(full_stage_) != frame_height_)) {
        gs_stagesurface_destroy(full_stage_);
        full_stage_ = nullptr;
    }
    if (!full_stage_)
        full_stage_ = gs_stagesurface_create(frame_width_, frame_height_, GS_BGRA);
    if (!full_stage_)
        return;
    gs_stage_texture(full_stage_, texture);
    uint8_t *data = nullptr;
    uint32_t linesize = 0;
    if (gs_stagesurface_map(full_stage_, &data, &linesize)) {
        ma2_submit_frame(context, data, linesize, frame_width_, frame_height_, frame_id_, now_ns);
        gs_stagesurface_unmap(full_stage_);
    }
}

void renderer::upload_matte(const ma2_matte &matte) {
    if (!matte_ || matte.width != working_width_ || matte.height != working_height_)
        return;
    gs_texture_set_image(matte_, matte.alpha, matte.width, false);
    matte_frame_id_ = matte.frame_id;
    has_matte_ = true;
}

void renderer::upload_overlay(const ma2_overlay &overlay) {
    if (!overlay.bgra || !overlay.width || !overlay.height)
        return;
    if (overlay_ && (overlay_width_ != overlay.width || overlay_height_ != overlay.height)) {
        gs_texture_destroy(overlay_);
        overlay_ = nullptr;
    }
    if (!overlay_) {
        overlay_ =
            gs_texture_create(overlay.width, overlay.height, GS_BGRA, 1, nullptr, GS_DYNAMIC);
        overlay_width_ = overlay.width;
        overlay_height_ = overlay.height;
    }
    if (overlay_)
        gs_texture_set_image(overlay_, overlay.bgra, overlay.stride, false);
}

// Premultiplied band scaled to the output width, drawn over whatever the
// filter produced (composite or passthrough).
void renderer::draw_overlay() {
    if (!overlay_ || !frame_width_ || !frame_height_)
        return;
    gs_effect_t *effect = obs_get_base_effect(OBS_EFFECT_DEFAULT);
    if (!effect)
        return;
    const float scale = static_cast<float>(frame_width_) / static_cast<float>(overlay_width_);

    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
    gs_matrix_push();
    gs_matrix_scale3f(scale, scale, 1.0f);
    gs_effect_set_texture(gs_effect_get_param_by_name(effect, "image"), overlay_);
    while (gs_effect_loop(effect, "Draw"))
        gs_draw_sprite(overlay_, 0, overlay_width_, overlay_height_);
    gs_matrix_pop();
    gs_blend_state_pop();
}

void renderer::clear_matte() {
    has_matte_ = false;
}

float renderer::draw(obs_source_t *filter, const render_params &params, uint64_t now_ns) {
    gs_texture_t *frame = current_ ? gs_texrender_get_texture(current_) : nullptr;
    float latency_ms = 0.0f;
    if (params.alignment == alignment_mode::aligned && !ring_ids_.empty()) {
        const alignment_choice choice = choose_aligned(ring_ids_, matte_frame_id_, now_ns);
        if (ring_[choice.slot]) {
            frame = gs_texrender_get_texture(ring_[choice.slot]);
            latency_ms = static_cast<float>(choice.latency_ns) / 1.0e6f;
        }
    }
    if (!frame || !has_matte_ || !composite_effect_) {
        obs_source_skip_video_filter(filter);
        return 0.0f;
    }
    const char *technique = "Draw";
    switch (params.preview) {
    case preview_mode::alpha:
        technique = "DrawAlpha";
        break;
    case preview_mode::checkerboard:
        technique = "DrawChecker";
        break;
    case preview_mode::off:
        break;
    }
    const bool previous_linear = gs_set_linear_srgb(true);
    const bool linear_srgb = gs_get_linear_srgb();
    draw_texture(frame, technique, params.refinement, linear_srgb);
    gs_set_linear_srgb(previous_linear);
    return latency_ms;
}

// One full-screen pass of guided.effect into a half-resolution texrender.
bool renderer::run_pass(gs_texrender_t *target, uint32_t width, uint32_t height,
                        const char *technique, gs_texture_t *source, gs_texture_t *extra,
                        float texel_x, float texel_y) {
    gs_texrender_reset(target);
    if (!gs_texrender_begin(target, width, height))
        return false;
    gs_ortho(0.0f, static_cast<float>(width), 0.0f, static_cast<float>(height), -100.0f, 100.0f);
    gs_effect_set_texture(gs_effect_get_param_by_name(guided_effect_, "image"), source);
    if (extra)
        gs_effect_set_texture(gs_effect_get_param_by_name(guided_effect_, "matte"), extra);
    vec2 texel;
    vec2_set(&texel, texel_x, texel_y);
    gs_effect_set_vec2(gs_effect_get_param_by_name(guided_effect_, "texel_size"), &texel);
    gs_effect_set_float(gs_effect_get_param_by_name(guided_effect_, "eps"), 0.001f);
    while (gs_effect_loop(guided_effect_, technique))
        gs_draw_sprite(source, 0, width, height);
    gs_texrender_end(target);
    return true;
}

gs_texture_t *renderer::guided_coefficients(gs_texture_t *frame, bool linear_srgb) {
    for (gs_texrender_t **texrender :
         {&guided_pack_, &guided_blur_a_, &guided_blur_b_, &guided_coeff_}) {
        if (!*texrender)
            *texrender = gs_texrender_create(GS_RGBA16F, GS_ZS_NONE);
        if (!*texrender)
            return nullptr;
    }
    const uint32_t width = frame_width_ / 2;
    const uint32_t height = frame_height_ / 2;
    const float tx = 1.0f / static_cast<float>(width);
    const float ty = 1.0f / static_cast<float>(height);

    const bool previous_framebuffer = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(false);
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);

    // Pack samples the frame the same way the composite does so the guide
    // luma matches between the passes and the final draw.
    gs_eparam_t *image = gs_effect_get_param_by_name(guided_effect_, "image");
    if (linear_srgb)
        gs_effect_set_texture_srgb(image, frame);
    else
        gs_effect_set_texture(image, frame);
    gs_texrender_reset(guided_pack_);
    bool ok = gs_texrender_begin(guided_pack_, width, height);
    if (ok) {
        gs_ortho(0.0f, static_cast<float>(width), 0.0f, static_cast<float>(height), -100.0f,
                 100.0f);
        gs_effect_set_texture(gs_effect_get_param_by_name(guided_effect_, "matte"), matte_);
        while (gs_effect_loop(guided_effect_, "Pack"))
            gs_draw_sprite(frame, 0, width, height);
        gs_texrender_end(guided_pack_);
    }
    ok = ok &&
         run_pass(guided_blur_a_, width, height, "BoxH", gs_texrender_get_texture(guided_pack_),
                  nullptr, tx, ty) &&
         run_pass(guided_blur_b_, width, height, "BoxV", gs_texrender_get_texture(guided_blur_a_),
                  nullptr, tx, ty) &&
         run_pass(guided_coeff_, width, height, "Coeff", gs_texrender_get_texture(guided_blur_b_),
                  nullptr, tx, ty) &&
         run_pass(guided_blur_a_, width, height, "BoxH", gs_texrender_get_texture(guided_coeff_),
                  nullptr, tx, ty) &&
         run_pass(guided_blur_b_, width, height, "BoxV", gs_texrender_get_texture(guided_blur_a_),
                  nullptr, tx, ty);

    gs_blend_state_pop();
    gs_enable_framebuffer_srgb(previous_framebuffer);
    return ok ? gs_texrender_get_texture(guided_blur_b_) : nullptr;
}

// Mirrors render_filter_tex in libobs so the output matches what
// obs_source_process_filter_end would produce for an OBS_SOURCE_SRGB filter.
void renderer::draw_texture(gs_texture_t *texture, const char *technique_name,
                            refinement_mode refinement, bool linear_srgb) {
    gs_texture_t *coefficients = nullptr;
    if (refinement == refinement_mode::guided) {
        coefficients = guided_coefficients(texture, linear_srgb);
        if (!coefficients)
            refinement = refinement_mode::none;
    }

    const bool previous_framebuffer = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(linear_srgb);

    gs_eparam_t *image = gs_effect_get_param_by_name(composite_effect_, "image");
    gs_eparam_t *lowres = gs_effect_get_param_by_name(composite_effect_, "lowres");
    gs_texture_t *lowres_texture = gs_texrender_get_texture(work_);
    if (linear_srgb) {
        gs_effect_set_texture_srgb(image, texture);
        gs_effect_set_texture_srgb(lowres, lowres_texture);
    } else {
        gs_effect_set_texture(image, texture);
        gs_effect_set_texture(lowres, lowres_texture);
    }
    gs_effect_set_texture(gs_effect_get_param_by_name(composite_effect_, "matte"), matte_);
    gs_effect_set_texture(gs_effect_get_param_by_name(composite_effect_, "coeff"),
                          coefficients ? coefficients : matte_);
    gs_effect_set_int(gs_effect_get_param_by_name(composite_effect_, "refinement"),
                      static_cast<int>(refinement));
    vec2 lowres_size;
    vec2_set(&lowres_size, static_cast<float>(working_width_), static_cast<float>(working_height_));
    gs_effect_set_vec2(gs_effect_get_param_by_name(composite_effect_, "lowres_size"), &lowres_size);
    vec2 output_size;
    vec2_set(&output_size, static_cast<float>(frame_width_), static_cast<float>(frame_height_));
    gs_effect_set_vec2(gs_effect_get_param_by_name(composite_effect_, "output_size"), &output_size);
    gs_effect_set_float(gs_effect_get_param_by_name(composite_effect_, "checker_size"), 32.0f);

    gs_technique_t *technique = gs_effect_get_technique(composite_effect_, technique_name);
    const size_t passes = gs_technique_begin(technique);
    for (size_t i = 0; i < passes; i++) {
        gs_technique_begin_pass(technique, i);
        gs_draw_sprite(texture, 0, frame_width_, frame_height_);
        gs_technique_end_pass(technique);
    }
    gs_technique_end(technique);

    gs_enable_framebuffer_srgb(previous_framebuffer);
}

} // namespace ma2
