// SPDX-License-Identifier: GPL-3.0-or-later

/// An 8-bit single-channel image at working resolution. 0 is background;
/// binary masks use 255 for foreground, soft masks use the full range.
public struct Mask: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public var count: Int { pixels.count }

    public var foregroundCount: Int {
        pixels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }

    /// Fraction of pixels that are foreground, 0...1.
    public var coverage: Double {
        Double(foregroundCount) / Double(count)
    }

    /// Per-pixel maximum.
    public func union(_ other: Mask) -> Mask {
        precondition(other.width == width && other.height == height)
        var out = self
        for i in out.pixels.indices {
            out.pixels[i] = max(pixels[i], other.pixels[i])
        }
        return out
    }

    /// Clears every pixel that is foreground in `other`.
    public func subtracting(_ other: Mask) -> Mask {
        precondition(other.width == width && other.height == height)
        var out = self
        for i in out.pixels.indices where other.pixels[i] > 0 {
            out.pixels[i] = 0
        }
        return out
    }

    /// 255 where the pixel is at least `threshold`, 0 elsewhere.
    /// Pixels set in both masks.
    public func intersecting(_ other: Mask) -> Mask {
        precondition(width == other.width && height == other.height)
        var out = self
        for i in out.pixels.indices where other.pixels[i] == 0 {
            out.pixels[i] = 0
        }
        return out
    }

    /// Jaccard overlap of the two foregrounds; 0 when both are empty.
    public func intersectionOverUnion(_ other: Mask) -> Double {
        precondition(width == other.width && height == other.height)
        var inter = 0
        var uni = 0
        for i in pixels.indices {
            let a = pixels[i] > 0
            let b = other.pixels[i] > 0
            if a && b { inter += 1 }
            if a || b { uni += 1 }
        }
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    public func thresholded(_ threshold: UInt8) -> Mask {
        var out = self
        for i in out.pixels.indices {
            out.pixels[i] = pixels[i] >= threshold ? 255 : 0
        }
        return out
    }

    /// Fills a rectangle, clipped to the mask bounds. Useful for tests and synthetic masks.
    public func fillingRect(x: Int, y: Int, width w: Int, height h: Int, value: UInt8) -> Mask {
        var out = self
        for yy in max(0, y)..<max(max(0, y), min(height, y + h)) {
            for xx in max(0, x)..<max(max(0, x), min(width, x + w)) {
                out[xx, yy] = value
            }
        }
        return out
    }
}
