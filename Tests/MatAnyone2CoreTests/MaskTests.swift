// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

@Suite struct MaskTests {
    @Test func unionTakesMaximum() {
        var a = Mask(width: 3, height: 1)
        var b = Mask(width: 3, height: 1)
        a[0, 0] = 255
        b[1, 0] = 128
        a[2, 0] = 10
        b[2, 0] = 20
        #expect(a.union(b).pixels == [255, 128, 20])
    }

    @Test func subtractingClearsWhereOtherIsSet() {
        let a = Mask(width: 2, height: 1, pixels: [255, 255])
        let b = Mask(width: 2, height: 1, pixels: [0, 1])
        #expect(a.subtracting(b).pixels == [255, 0])
    }

    @Test func thresholdBinarises() {
        let a = Mask(width: 3, height: 1, pixels: [0, 127, 128])
        #expect(a.thresholded(128).pixels == [0, 0, 255])
        #expect(a.foregroundCount == 2)
    }

    @Test func fillingRectClampsToBounds() {
        let m = Mask(width: 4, height: 4).fillingRect(x: 2, y: 2, width: 5, height: 5, value: 255)
        #expect(m.foregroundCount == 4)
        #expect(m[3, 3] == 255)
        #expect(m[1, 1] == 0)
    }

    @Test func coverageIsForegroundFraction() {
        let m = Mask(width: 10, height: 10).fillingRect(x: 0, y: 0, width: 5, height: 2, value: 255)
        #expect(m.coverage == 0.1)
    }
}
