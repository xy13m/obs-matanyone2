// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

struct LivePropsTests {
    let w = 64
    let h = 32

    func plate(rects: [(x: Int, y: Int, w: Int, h: Int)]) -> Plate {
        var p = Plate(width: w, height: h, fill: (b: 40, g: 40, r: 40))
        for r in rects {
            for y in r.y..<r.y + r.h {
                for x in r.x..<r.x + r.w {
                    let i = (y * w + x) * 4
                    p.bgra[i] = 200
                    p.bgra[i + 1] = 200
                    p.bgra[i + 2] = 200
                }
            }
        }
        return p
    }

    @Test func keepsAMovedPropThatStillOverlapsItsCalibratedRegion() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 40, y: 8, width: 12, height: 12, value: 255)
        // The chair rolled a third of its width to the right since calibration;
        // more than half of it still sits over the calibrated region.
        let current = plate(rects: [(x: 44, y: 8, w: 12, h: 12)])
        let person = Mask(width: w, height: h).fillingRect(
            x: 0, y: 0, width: 16, height: h, value: 255)
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated, person: person,
            threshold: 16, minRegion: 8)
        #expect(live[54, 14] == 255)  // inside the moved chair, outside the old mask
        #expect(live[41, 14] == 0)  // old position is background now
    }

    @Test func dropsNewObjectsThatDoNotTouchCalibratedRegions() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 40, y: 8, width: 12, height: 12, value: 255)
        let current = plate(rects: [(x: 40, y: 8, w: 12, h: 12), (x: 20, y: 2, w: 8, h: 8)])
        let person = Mask(width: w, height: h)
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated, person: person,
            threshold: 16, minRegion: 8)
        #expect(live[45, 14] == 255)
        #expect(live[24, 6] == 0)
    }

    @Test func removesThePersonAndABorderAroundThem() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 10, y: 0, width: 30, height: h, value: 255)
        // The person now stands where the calibrated region is.
        let current = plate(rects: [(x: 10, y: 0, w: 30, h: h)])
        let person = Mask(width: w, height: h).fillingRect(
            x: 10, y: 0, width: 20, height: h, value: 255)
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated, person: person,
            threshold: 16, minRegion: 8)
        #expect(live[20, 10] == 0)
        #expect(live[30, 10] == 0)  // within 2 px of the person
        #expect(live[36, 10] == 255)
    }

    @Test func ignoresAGlobalLightingChange() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 40, y: 8, width: 12, height: 12, value: 255)
        // The room light went off: every pixel differs from the clean plate.
        var current = plate(rects: [])
        for i in stride(from: 0, to: current.bgra.count, by: 4) {
            current.bgra[i] = 10
            current.bgra[i + 1] = 10
            current.bgra[i + 2] = 10
        }
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated,
            person: Mask(width: w, height: h),
            threshold: 16, minRegion: 8)
        #expect(live.foregroundCount == 0)
    }

    @Test func dropsARegionThatMostlyLiesOutsideItsCalibratedArea() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 40, y: 8, width: 8, height: 8, value: 255)
        // A shadow four times the size of the prop, touching it.
        let current = plate(rects: [(x: 24, y: 4, w: 32, h: 16)])
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated,
            person: Mask(width: w, height: h),
            threshold: 16, minRegion: 8)
        #expect(live.foregroundCount == 0)
    }

    @Test func keepsTheVisiblePartWhenThePersonHidesMostOfTheProps() {
        let clean = plate(rects: [])
        let calibrated = Mask(width: w, height: h).fillingRect(
            x: 30, y: 4, width: 24, height: 24, value: 255)
        // Only a corner of the calibrated props shows; the rest is behind the person.
        let current = plate(rects: [(x: 30, y: 4, w: 6, h: 6)])
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated,
            person: Mask(width: w, height: h), threshold: 16, minRegion: 8)
        #expect(live[32, 6] == 255)
        #expect(live[50, 20] == 0)
    }

    @Test func maskIntersectionOverUnion() {
        let a = Mask(width: 10, height: 1).fillingRect(x: 0, y: 0, width: 6, height: 1, value: 255)
        let b = Mask(width: 10, height: 1).fillingRect(x: 3, y: 0, width: 6, height: 1, value: 255)
        #expect(a.intersectionOverUnion(b) == 3.0 / 9.0)
        #expect(Mask(width: 10, height: 1).intersectionOverUnion(Mask(width: 10, height: 1)) == 0)
    }
}

struct AutoSeedGateTests {
    let full = Mask(width: 20, height: 10).fillingRect(
        x: 0, y: 0, width: 10, height: 10, value: 255)

    @Test func needsTwoStableObservations() {
        var gate = AutoSeedGate()
        #expect(gate.admit(full) == false)
        #expect(gate.admit(full) == true)
    }

    @Test func rejectsAPersonStillMovingIntoFrame() {
        var gate = AutoSeedGate()
        let entering = Mask(width: 20, height: 10).fillingRect(
            x: 0, y: 0, width: 4, height: 10, value: 255)
        #expect(gate.admit(entering) == false)
        #expect(gate.admit(full) == false)  // overlap 0.4, not stable yet
        #expect(gate.admit(full) == true)
    }

    @Test func rejectsTinyCoverageEvenWhenStable() {
        var gate = AutoSeedGate()
        let tiny = Mask(width: 20, height: 10).fillingRect(
            x: 0, y: 0, width: 1, height: 4, value: 255)
        #expect(gate.admit(tiny) == false)
        #expect(gate.admit(tiny) == false)
    }

    @Test func resetForgetsThePreviousObservation() {
        var gate = AutoSeedGate()
        _ = gate.admit(full)
        gate.reset()
        #expect(gate.admit(full) == false)
    }
}
