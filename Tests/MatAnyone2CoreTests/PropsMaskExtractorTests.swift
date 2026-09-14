// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

@Suite struct PlateTests {
    @Test func accumulatorAveragesDistinctFrames() {
        var acc = PlateAccumulator(width: 1, height: 1, targetFrames: 2)
        #expect(acc.add(bgra: [10, 20, 30, 255], frameID: 1) == false)
        #expect(acc.add(bgra: [10, 20, 30, 255], frameID: 1) == false)
        #expect(acc.framesAdded == 1)
        #expect(acc.add(bgra: [20, 40, 61, 255], frameID: 2) == true)
        #expect(acc.isComplete)
        #expect(acc.result()?.bgra == [15, 30, 46, 255])
    }

    @Test func accumulatorIgnoresFramesAfterCompletion() {
        var acc = PlateAccumulator(width: 1, height: 1, targetFrames: 1)
        #expect(acc.add(bgra: [10, 10, 10, 255], frameID: 1) == true)
        #expect(acc.add(bgra: [90, 90, 90, 255], frameID: 2) == true)
        #expect(acc.result()?.bgra == [10, 10, 10, 255])
    }

    @Test func resultIsNilBeforeAnyFrame() {
        #expect(PlateAccumulator(width: 2, height: 2, targetFrames: 4).result() == nil)
    }
}

@Suite struct PropsMaskExtractorTests {
    private static let width = 64
    private static let height = 36

    /// Clean plate with deterministic low-amplitude noise; props plate adds a
    /// 12x10 "chair" at (propX, propY), a 3 px thick "boom arm" on rows 2-4
    /// from x = 5 to 39, and two isolated specks.
    private func plates(propX: Int, propY: Int) -> (clean: Plate, props: Plate) {
        let w = Self.width
        var clean = Plate(width: w, height: Self.height, fill: (b: 40, g: 42, r: 44))
        for i in stride(from: 0, to: clean.bgra.count, by: 4) {
            clean.bgra[i] = 40 &+ UInt8((i / 4) % 5)
        }
        var props = clean
        func paint(x: Int, y: Int, value: UInt8) {
            let p = (y * w + x) * 4
            props.bgra[p] = value
            props.bgra[p + 1] = value
            props.bgra[p + 2] = value
        }
        for y in propY..<propY + 10 {
            for x in propX..<propX + 12 { paint(x: x, y: y, value: 120) }
        }
        for y in 2..<5 {
            for x in 5..<40 { paint(x: x, y: y, value: 130) }
        }
        paint(x: 50, y: 30, value: 200)
        paint(x: 60, y: 5, value: 200)
        return (clean, props)
    }

    @Test(arguments: [(0, 20), (26, 13), (52, 26)])
    func chairSurvivesAnywhere(propX: Int, propY: Int) {
        let (clean, props) = plates(propX: propX, propY: propY)
        let r = PropsMaskExtractor.extract(clean: clean, props: props, threshold: 16, minRegion: 8)
        #expect(r.mask[propX + 5, propY + 5] == 255)
        #expect(r.mask[50, 30] == 0)
        #expect(r.mask[60, 5] == 0)
    }

    @Test func thinArmSurvivesOpening() {
        let (clean, props) = plates(propX: 30, propY: 20)
        let r = PropsMaskExtractor.extract(clean: clean, props: props, threshold: 16, minRegion: 8)
        #expect(r.mask[20, 3] == 255)
        #expect(r.mask[20, 1] == 255)  // grown by the final one-pixel dilation
        #expect(r.mask[20, 0] == 0)
        #expect(r.regionCount == 2)
    }

    @Test func minRegionDropsSmallRegions() {
        let (clean, props) = plates(propX: 30, propY: 20)
        let r = PropsMaskExtractor.extract(
            clean: clean, props: props, threshold: 16, minRegion: 500)
        #expect(r.regionCount == 0)
        #expect(r.mask.foregroundCount == 0)
    }

    @Test func thresholdAboveDifferenceGivesEmptyMask() {
        let (clean, props) = plates(propX: 30, propY: 20)
        #expect(PropsMaskExtractor.difference(clean: clean, props: props)[35, 25] >= 76)
        let r = PropsMaskExtractor.extract(clean: clean, props: props, threshold: 100, minRegion: 8)
        #expect(r.mask.foregroundCount == 0)
    }

    @Test func noiseAloneProducesNothing() {
        let (clean, _) = plates(propX: 30, propY: 20)
        let r = PropsMaskExtractor.extract(clean: clean, props: clean, threshold: 4, minRegion: 8)
        #expect(r.mask.foregroundCount == 0)
    }
}
