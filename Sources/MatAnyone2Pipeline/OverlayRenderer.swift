// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreText
import Foundation

/// Draws the calibration overlay band with Core Text: a translucent dark
/// strip with a title and a detail line. Output is premultiplied BGRA, row 0
/// at the top, ready for gs_texture_set_image.
public final class OverlayRenderer {
    public static let width = 1280
    public static let height = 120
    public static let bytesPerRow = width * 4
    public static let bandAlpha: CGFloat = 0.62

    private let pixels: UnsafeMutableRawPointer
    private let context: CGContext
    private let titleFont: CTFont
    private let detailFont: CTFont

    public init() {
        pixels = .allocate(byteCount: Self.bytesPerRow * Self.height, alignment: 16)
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        context = CGContext(
            data: pixels, width: Self.width, height: Self.height, bitsPerComponent: 8,
            bytesPerRow: Self.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: info)!
        titleFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 44, nil)
        detailFont = CTFontCreateWithName("HelveticaNeue" as CFString, 28, nil)
    }

    deinit {
        pixels.deallocate()
    }

    public func render(title: String, detail: String) -> [UInt8] {
        context.clear(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        context.setFillColor(CGColor(gray: 0, alpha: Self.bandAlpha))
        context.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))

        draw(title, font: titleFont, y: detail.isEmpty ? 42 : 62)
        if !detail.isEmpty {
            draw(detail, font: detailFont, y: 20)
        }
        return [UInt8](
            UnsafeRawBufferPointer(start: pixels, count: Self.bytesPerRow * Self.height))
    }

    private func draw(_ text: String, font: CTFont, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 28, y: y)
        CTLineDraw(line, context)
    }
}
