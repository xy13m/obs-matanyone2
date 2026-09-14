// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

@Suite struct ConnectedComponentsTests {
    @Test func labelsDiagonalPixelsAsOneComponent() {
        var m = Mask(width: 4, height: 4)
        m[0, 0] = 255
        m[1, 1] = 255
        m[3, 3] = 255
        let cc = ConnectedComponents.label(m)
        #expect(cc.count == 2)
        #expect(cc.labels[0] == cc.labels[5])
        #expect(cc.labels[15] != cc.labels[0])
        #expect(cc.areas.sorted() == [1, 2])
    }

    @Test func removesSmallComponentsAnywhere() {
        let m = Mask(width: 20, height: 20)
            .fillingRect(x: 0, y: 0, width: 2, height: 2, value: 255)
            .fillingRect(x: 9, y: 9, width: 3, height: 3, value: 255)
            .fillingRect(x: 18, y: 5, width: 2, height: 10, value: 255)
        let kept = m.removingComponents(smallerThan: 9)
        #expect(kept[0, 0] == 0)
        #expect(kept[10, 10] == 255)
        #expect(kept[19, 10] == 255)
        #expect(kept.foregroundCount == 29)
    }

    @Test func speckMinimumAreaScalesWithResolution() {
        #expect(SpeckFilter.minimumArea(pixelCount: 512 * 288) == 24)
        #expect(SpeckFilter.minimumArea(pixelCount: 768 * 432) == 53)
    }

    @Test func removeSpecksZeroesSmallRegionsOnly() {
        var alpha = [Float](repeating: 0, count: 10 * 10)
        alpha[0] = 0.9
        for y in 4..<8 {
            for x in 4..<8 { alpha[y * 10 + x] = 0.7 }
        }
        let removed = SpeckFilter.removeSpecks(alpha: &alpha, width: 10, height: 10, minArea: 4)
        #expect(removed == 1)
        #expect(alpha[0] == 0)
        #expect(alpha[55] == 0.7)
    }

    @Test func removeSpecksLeavesSoftBackgroundAlone() {
        var alpha = [Float](repeating: 0.3, count: 9)
        let removed = SpeckFilter.removeSpecks(alpha: &alpha, width: 3, height: 3, minArea: 4)
        #expect(removed == 0)
        #expect(alpha.allSatisfy { $0 == 0.3 })
    }
}
