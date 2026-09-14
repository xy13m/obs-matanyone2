// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MatAnyone2Pipeline

@Suite struct OverlayRendererTests {
    @Test func bandIsTranslucentAndTextIsDrawn() {
        let renderer = OverlayRenderer()
        let bytes = renderer.render(
            title: "Capturing clean plate in 2.1 s", detail: "Leave the frame")
        #expect(bytes.count == OverlayRenderer.bytesPerRow * OverlayRenderer.height)
        // Top-left pixel: band only, alpha about 62 %.
        #expect(bytes[3] > 150 && bytes[3] < 170)
        #expect(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0)
        // Some pixel is bright white text (premultiplied, so alpha 255).
        var white = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 200 && bytes[i + 3] == 255
        {
            white += 1
        }
        #expect(white > 500)
    }

    @Test func differentTextGivesDifferentPixels() {
        let renderer = OverlayRenderer()
        let a = renderer.render(title: "Tracking", detail: "")
        let b = renderer.render(title: "Error", detail: "No person detected")
        #expect(a != b)
        #expect(renderer.render(title: "Tracking", detail: "") == a)
    }
}
