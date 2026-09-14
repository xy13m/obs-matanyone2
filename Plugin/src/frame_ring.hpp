// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace ma2 {

// Bookkeeping for the aligned frame/matte mode: which frame id sits in which
// texture slot, and which slot to draw when a matte for a given frame
// arrives. No OBS types, so it is unit tested on its own.
template <size_t N> struct frame_ring {
    static_assert(N >= 2, "a ring needs at least two slots");

    struct slot {
        uint64_t frame_id = 0;
        uint64_t capture_ns = 0;
        bool valid = false;
    };

    std::array<slot, N> slots{};
    size_t next = 0;
    size_t newest = 0;

    // Records a frame and returns the slot the caller must render it into.
    size_t push(uint64_t frame_id, uint64_t capture_ns) {
        const size_t index = next;
        slots[index] = slot{frame_id, capture_ns, true};
        newest = index;
        next = (next + 1) % N;
        return index;
    }

    // Slot holding frame_id, or nullopt once it has been overwritten.
    std::optional<size_t> find(uint64_t frame_id) const {
        for (size_t i = 0; i < N; i++) {
            if (slots[i].valid && slots[i].frame_id == frame_id)
                return i;
        }
        return std::nullopt;
    }

    bool empty() const { return !slots[newest].valid; }

    void clear() {
        slots.fill(slot{});
        next = 0;
        newest = 0;
    }
};

struct alignment_choice {
    size_t slot = 0;
    // True when the slot holds the exact frame the matte was computed from.
    bool aligned = false;
    // Capture-to-now latency of the drawn frame when aligned, else 0.
    uint64_t latency_ns = 0;
};

// Picks the frame to composite with the newest matte. When the matte's frame
// was already evicted (inference slower than the ring), the newest frame is
// used so the output never stalls.
template <size_t N>
alignment_choice choose_aligned(const frame_ring<N> &ring, uint64_t matte_frame_id,
                                uint64_t now_ns) {
    if (const auto found = ring.find(matte_frame_id)) {
        const uint64_t capture = ring.slots[*found].capture_ns;
        return alignment_choice{*found, true, now_ns > capture ? now_ns - capture : 0};
    }
    return alignment_choice{ring.newest, false, 0};
}

} // namespace ma2
