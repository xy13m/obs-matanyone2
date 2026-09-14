// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unit tests for Plugin/src/frame_ring.hpp. Run with `swift run FrameRingTests`.

#include "frame_ring.hpp"

#include <cstdio>
#include <cstdlib>

namespace {

int failures = 0;

#define CHECK(condition)                                                                           \
    do {                                                                                           \
        if (!(condition)) {                                                                        \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);              \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

void push_returns_slots_in_order_and_evicts_oldest() {
    ma2::frame_ring<4> ring;
    CHECK(ring.empty());
    CHECK(ring.push(1, 100) == 0);
    CHECK(ring.push(2, 200) == 1);
    CHECK(ring.push(3, 300) == 2);
    CHECK(ring.push(4, 400) == 3);
    CHECK(ring.push(5, 500) == 0); // overwrites frame 1
    CHECK(!ring.find(1).has_value());
    CHECK(ring.find(2).value() == 1);
    CHECK(ring.find(5).value() == 0);
    CHECK(ring.newest == 0);
    CHECK(!ring.empty());
}

void choose_aligned_uses_matching_frame_and_measures_latency() {
    ma2::frame_ring<4> ring;
    ring.push(10, 1000);
    ring.push(11, 2000);
    ring.push(12, 3000);
    const auto choice = ma2::choose_aligned(ring, 11, 5000);
    CHECK(choice.aligned);
    CHECK(choice.slot == 1);
    CHECK(choice.latency_ns == 3000);
}

void choose_aligned_falls_back_to_newest_when_evicted() {
    ma2::frame_ring<2> ring;
    ring.push(1, 100);
    ring.push(2, 200);
    ring.push(3, 300); // evicts 1
    const auto choice = ma2::choose_aligned(ring, 1, 400);
    CHECK(!choice.aligned);
    CHECK(choice.slot == ring.newest);
    CHECK(choice.latency_ns == 0);
}

void clear_forgets_everything() {
    ma2::frame_ring<3> ring;
    ring.push(7, 70);
    ring.clear();
    CHECK(ring.empty());
    CHECK(!ring.find(7).has_value());
    CHECK(ring.push(8, 80) == 0);
}

void latency_never_underflows() {
    ma2::frame_ring<2> ring;
    ring.push(1, 5000);
    const auto choice = ma2::choose_aligned(ring, 1, 4000);
    CHECK(choice.aligned);
    CHECK(choice.latency_ns == 0);
}

} // namespace

int main() {
    push_returns_slots_in_order_and_evicts_oldest();
    choose_aligned_uses_matching_frame_and_measures_latency();
    choose_aligned_falls_back_to_newest_when_evicted();
    clear_forgets_everything();
    latency_never_underflows();
    if (failures) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return EXIT_FAILURE;
    }
    std::printf("frame_ring tests passed\n");
    return EXIT_SUCCESS;
}
