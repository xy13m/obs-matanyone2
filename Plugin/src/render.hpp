// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include "frame_ring.hpp"

#include <MatAnyone2Bridge.h>
#include <obs-module.h>

#include <array>
#include <cstdint>

namespace ma2 {

enum class preview_mode { off = 0, alpha = 1, checkerboard = 2 };
enum class refinement_mode { none = 0, bilateral = 1, guided = 2 };
enum class alignment_mode { lowest_latency = 0, aligned = 1 };

struct render_params {
    preview_mode preview = preview_mode::off;
    refinement_mode refinement = refinement_mode::none;
    alignment_mode alignment = alignment_mode::lowest_latency;
    bool gpu_downscale = true;
};

// GPU side of the filter. Every method runs on the OBS graphics thread. All
// textures are created once in init() and reused; nothing is allocated per
// frame.
class renderer {
  public:
    renderer() = default;
    renderer(const renderer &) = delete;
    renderer &operator=(const renderer &) = delete;
    ~renderer();

    // Loads the effects and creates the working-resolution resources. Must be
    // called between obs_enter_graphics / obs_leave_graphics.
    bool init(uint32_t working_width, uint32_t working_height);
    void destroy();

    // Renders the filter target into the full-resolution texrender, downscales
    // it into the working-resolution texrender, stages that copy and submits
    // the frame staged two calls ago to the worker. Returns false when the
    // target has no size yet.
    bool capture(obs_source_t *filter, ma2_context_t context, const render_params &params,
                 uint64_t now_ns);

    // Uploads a new matte into the persistent R8 texture.
    void upload_matte(const ma2_matte &matte);
    // Forgets the current matte so the next draw passes the source through.
    void clear_matte();
    bool has_matte() const { return has_matte_; }

    // Draws the composite for the current frame. Falls back to
    // obs_source_skip_video_filter when there is no matte or no frame. In
    // aligned mode returns the capture-to-display latency of the drawn pair
    // in milliseconds, otherwise 0.
    float draw(obs_source_t *filter, const render_params &params, uint64_t now_ns);

    // Uploads a new overlay band and draws it across the top of the output.
    void upload_overlay(const ma2_overlay &overlay);
    void draw_overlay();

    uint32_t working_width() const { return working_width_; }
    uint32_t working_height() const { return working_height_; }

  private:
    bool render_target(obs_source_t *filter, gs_texrender_t *into);
    void downscale(gs_texture_t *source);
    gs_texrender_t *ring_texrender(size_t slot);
    void stage_and_submit(ma2_context_t context, uint64_t now_ns);
    void submit_full_resolution(ma2_context_t context, uint64_t now_ns);
    void draw_texture(gs_texture_t *texture, const char *technique, refinement_mode refinement,
                      bool linear_srgb);
    // Runs the guided filter passes at half resolution; returns the (a, b)
    // coefficient texture or nullptr when the passes could not run.
    gs_texture_t *guided_coefficients(gs_texture_t *frame, bool linear_srgb);
    bool run_pass(gs_texrender_t *target, uint32_t width, uint32_t height, const char *technique,
                  gs_texture_t *source, gs_texture_t *extra, float texel_x, float texel_y);

    uint32_t working_width_ = 0;
    uint32_t working_height_ = 0;
    uint32_t frame_width_ = 0;
    uint32_t frame_height_ = 0;
    uint64_t frame_id_ = 0;
    uint64_t last_frame_time_ = 0;
    // The texrender holding the frame captured this call: full_ in lowest
    // latency mode, a ring slot in aligned mode.
    gs_texrender_t *current_ = nullptr;
    uint64_t matte_frame_id_ = 0;

    gs_effect_t *downscale_effect_ = nullptr;
    gs_effect_t *composite_effect_ = nullptr;
    gs_effect_t *guided_effect_ = nullptr;
    // Guided filter intermediates (RGBA16F, half resolution), created on first use.
    gs_texrender_t *guided_pack_ = nullptr;
    gs_texrender_t *guided_blur_a_ = nullptr;
    gs_texrender_t *guided_blur_b_ = nullptr;
    gs_texrender_t *guided_coeff_ = nullptr;
    gs_texrender_t *full_ = nullptr;
    gs_texrender_t *work_ = nullptr;
    gs_texture_t *matte_ = nullptr;
    bool has_matte_ = false;
    // Aligned mode keeps recent full-resolution frames so each matte can be
    // composited with the frame it was computed from. Created on first use.
    static constexpr size_t ring_size = 6;
    std::array<gs_texrender_t *, ring_size> ring_{};
    frame_ring<ring_size> ring_ids_;
    gs_texture_t *overlay_ = nullptr;
    uint32_t overlay_width_ = 0;
    uint32_t overlay_height_ = 0;

    // Three-deep staging ring: stage frame N, map frame N-2 so the map never
    // waits for the GPU.
    struct stage_slot {
        gs_stagesurf_t *surface = nullptr;
        uint64_t frame_id = 0;
        uint64_t capture_ns = 0;
        bool valid = false;
    };
    std::array<stage_slot, 3> stages_{};
    size_t stage_index_ = 0;
    // Full-resolution staging is only used when GPU downscale is off.
    gs_stagesurf_t *full_stage_ = nullptr;
};

} // namespace ma2
