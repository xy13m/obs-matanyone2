// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

@Suite struct SeedComposerTests {
    @Test func initialSeedIsUnion() throws {
        let person = Mask(width: 10, height: 10).fillingRect(
            x: 0, y: 0, width: 5, height: 5, value: 255)
        let props = Mask(width: 10, height: 10).fillingRect(
            x: 7, y: 7, width: 2, height: 2, value: 255)
        let seed = try SeedComposer.initialSeed(person: person, props: props)
        #expect(seed.foregroundCount == 29)
    }

    @Test func initialSeedRejectsTinyPerson() {
        let person = Mask(width: 100, height: 100).fillingRect(
            x: 0, y: 0, width: 3, height: 3, value: 255)
        #expect(throws: SeedComposer.Failure.noPerson(coverage: 0.0009)) {
            try SeedComposer.initialSeed(person: person, props: Mask(width: 100, height: 100))
        }
    }

    @Test func refreshSeedKeepsTrackedPropsNotSpecks() throws {
        let person = Mask(width: 10, height: 10).fillingRect(
            x: 0, y: 0, width: 5, height: 5, value: 255)
        var alpha = [Float](repeating: 0, count: 100)
        for y in 0..<5 {
            for x in 0..<5 { alpha[y * 10 + x] = 1 }
        }
        for y in 6..<9 {
            for x in 6..<9 { alpha[y * 10 + x] = 0.8 }
        }
        alpha[90] = 0.9  // isolated speck at (0, 9)
        let seed = try SeedComposer.refreshSeed(
            person: person, trackedAlpha: alpha, minSpeckArea: 4)
        #expect(seed[7, 7] == 255)
        #expect(seed[0, 9] == 0)
        #expect(seed.foregroundCount == 34)
    }

    /// The tracker tends to spread from the person into a similar-looking
    /// background right behind them. Tracked props that look the same as the
    /// clean plate are not props and must not survive a re-seed.
    @Test func refreshSeedDropsTrackedPixelsThatMatchTheCleanPlate() throws {
        let person = Mask(width: 10, height: 10).fillingRect(
            x: 0, y: 0, width: 3, height: 10, value: 255)
        var alpha = [Float](repeating: 0, count: 100)
        for y in 0..<10 {
            for x in 0..<3 { alpha[y * 10 + x] = 1 }  // person
            for x in 3..<9 { alpha[y * 10 + x] = 0.9 }  // tracked beyond the person
        }
        // Only x 6..8 differ from the clean plate (a prop); x 3..5 is background.
        let changed = Mask(width: 10, height: 10).fillingRect(
            x: 6, y: 0, width: 3, height: 10, value: 255)
        let seed = try SeedComposer.refreshSeed(
            person: person, trackedAlpha: alpha, minSpeckArea: 1, changed: changed)
        #expect(seed[7, 5] == 255)
        #expect(seed[5, 5] == 255)  // within the 2 px margin around the change
        #expect(seed[3, 5] == 0)
        #expect(seed[1, 5] == 255)
    }

    @Test func trackedPropsExcludesPerson() {
        let person = Mask(width: 4, height: 1, pixels: [255, 255, 0, 0])
        let props = SeedComposer.trackedProps(
            person: person, trackedAlpha: [1, 1, 1, 0.2], minSpeckArea: 1)
        #expect(props.pixels == [0, 0, 255, 0])
    }

    @Test func personMaskBinarisesAtQuarterAndDilates() {
        var soft = Mask(width: 5, height: 5)
        soft[2, 2] = 64
        soft[0, 0] = 63
        let p = SeedComposer.personMask(fromSoft: soft)
        #expect(p.foregroundCount == 9)
        #expect(p[0, 0] == 0)
    }

    @Test func seedFloatsAreZeroOrOne() {
        let m = Mask(width: 2, height: 1, pixels: [255, 0])
        #expect(m.seedFloats == [1, 0])
    }
}

@Suite struct AlphaSmootherTests {
    @Test func zeroWeightPassesThrough() {
        var s = AlphaSmoother(weight: 0)
        var a: [Float] = [1, 0]
        s.apply(&a)
        s.apply(&a)
        #expect(a == [1, 0])
    }

    @Test func blendsWithPreviousAndResets() {
        var s = AlphaSmoother(weight: 0.5)
        var a: [Float] = [1]
        s.apply(&a)
        var b: [Float] = [0]
        s.apply(&b)
        #expect(b == [0.5])
        s.reset()
        var c: [Float] = [0]
        s.apply(&c)
        #expect(c == [0])
    }
}

@Suite struct StatusTests {
    @Test func trackingLineHasRatesAndResolution() {
        var s = StatusSnapshot(phase: .tracking)
        s.matteFPS = 48.12
        s.inferenceP50 = 17.24
        s.inferenceP95 = 19
        s.matteAgeMs = 21.4
        s.workingWidth = 512
        s.workingHeight = 288
        #expect(
            StatusFormatter.panelText(s)
                == "Tracking · 48.1 matte fps · inference 17.2 ms (p95 19.0) · matte age 21 ms · 512x288"
        )
    }

    @Test func trackingLineShowsAlignedLatencyAndDrops() {
        var s = StatusSnapshot(phase: .tracking)
        s.alignedLatencyMs = 33.3
        s.droppedFrames = 7
        s.workingWidth = 768
        s.workingHeight = 432
        #expect(
            StatusFormatter.panelText(s)
                == "Tracking · 0.0 matte fps · inference 0.0 ms (p95 0.0) · aligned +33 ms · 7 dropped · 768x432"
        )
    }

    @Test func countdownLine() {
        var s = StatusSnapshot(phase: .capturingClean)
        s.countdownRemaining = 2.06
        let lines = StatusFormatter.overlayLines(s)
        #expect(lines.title == "Capturing clean plate in 2.1 s")
        #expect(lines.detail == "Leave the frame")
        #expect(StatusFormatter.panelText(s) == "Capturing clean plate in 2.1 s. Leave the frame.")
    }

    @Test func errorShowsMessage() {
        var s = StatusSnapshot(phase: .error)
        s.message = "No person detected"
        #expect(StatusFormatter.panelText(s) == "Error: No person detected")
        #expect(StatusFormatter.overlayLines(s).title == "Error")
    }

    @Test func propsCapturedShowsRegionCount() {
        var s = StatusSnapshot(phase: .propsCaptured)
        s.propsRegions = 3
        #expect(StatusFormatter.panelText(s).contains("3 regions"))
    }
}
