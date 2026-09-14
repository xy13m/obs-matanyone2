// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Pipeline

@Suite struct FrameBufferTests {
    @Test func copyHonoursStride() {
        let b = FrameBuffer(width: 2, height: 2)
        let src: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 99, 99, 99, 99,
            9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0,
        ]
        src.withUnsafeBufferPointer { b.copy(from: $0.baseAddress!, stride: 12) }
        #expect(b.bgra == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    }

    @Test func poolHandsOutAtMostCapacity() {
        let pool = FrameBufferPool(width: 1, height: 1, capacity: 2)
        let a = pool.take()
        let b = pool.take()
        #expect(a != nil)
        #expect(b != nil)
        #expect(pool.take() == nil)
        pool.give(a!)
        #expect(pool.take() != nil)
    }
}

@Suite struct PreprocessTests {
    @Test func rgbPlanarSplitsChannelsAndScales() {
        let f = FrameBuffer(width: 2, height: 1)
        f.bgra = [255, 0, 51, 255, 0, 255, 102, 255]
        var out = [Float](repeating: -1, count: 6)
        FramePreprocessor(width: 2, height: 1).rgbPlanar(from: f, into: &out)
        let expected: [Float] = [0.2, 0.4, 0, 1, 1, 0]
        for (got, want) in zip(out, expected) {
            #expect(abs(got - want) < 1e-6)
        }
    }

    @Test func downscaleAveragesBlocks() {
        let f = FrameBuffer(width: 4, height: 4)
        f.bgra = [UInt8](repeating: 200, count: 64)
        f.frameID = 7
        let out = FrameBuffer(width: 2, height: 2)
        FramePreprocessor.downscale(f, into: out)
        #expect(out.bgra.allSatisfy { $0 == 200 })
        #expect(out.frameID == 7)
    }
}

@Suite struct TimingStatsTests {
    @Test func percentilesOverAHundredSamples() {
        var t = TimingStats()
        for v in 1...100 { t.add(Double(v)) }
        #expect(t.p50 == 50)
        #expect(t.p95 == 95)
        #expect(t.count == 100)
    }

    @Test func ringKeepsOnlyTheNewest() {
        var t = TimingStats(capacity: 3)
        for v in [100.0, 1, 2, 3] { t.add(v) }
        #expect(t.count == 3)
        #expect(t.p50 == 2)
        #expect(t.p95 <= 3)
        #expect(t.mean == 2)
    }

    @Test func emptyIsZero() {
        #expect(TimingStats().p50 == 0)
    }
}
