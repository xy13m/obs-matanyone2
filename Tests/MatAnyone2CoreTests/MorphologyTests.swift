// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Core

@Suite struct MorphologyTests {
    @Test func dilateGrowsSinglePixelToSquare() {
        var m = Mask(width: 5, height: 5)
        m[2, 2] = 255
        let d = m.dilated(radius: 1)
        #expect(d.foregroundCount == 9)
        #expect(d[1, 1] == 255)
        #expect(d[0, 0] == 0)
    }

    @Test func erodeRemovesThinLine() {
        let m = Mask(width: 7, height: 7).fillingRect(x: 0, y: 3, width: 7, height: 1, value: 255)
        #expect(m.eroded(radius: 1).foregroundCount == 0)
    }

    @Test func openRemovesOnePixelLineKeepsBlock() {
        let m = Mask(width: 12, height: 12)
            .fillingRect(x: 0, y: 1, width: 12, height: 1, value: 255)
            .fillingRect(x: 4, y: 4, width: 5, height: 5, value: 255)
        let o = m.opened(radius: 1)
        #expect(o[6, 1] == 0)
        #expect(o.foregroundCount == 25)
    }

    @Test func closeFillsOnePixelHole() {
        var m = Mask(width: 9, height: 9).fillingRect(x: 2, y: 2, width: 5, height: 5, value: 255)
        m[4, 4] = 0
        let c = m.closed(radius: 1)
        #expect(c[4, 4] == 255)
        #expect(c.foregroundCount == 25)
    }

    @Test func dilateClampsAtEdges() {
        var m = Mask(width: 3, height: 3)
        m[0, 0] = 255
        #expect(m.dilated(radius: 1).foregroundCount == 4)
    }

    @Test func zeroRadiusIsIdentity() {
        let m = Mask(width: 4, height: 4).fillingRect(x: 1, y: 1, width: 2, height: 2, value: 200)
        #expect(m.dilated(radius: 0) == m)
        #expect(m.eroded(radius: 0) == m)
    }
}
