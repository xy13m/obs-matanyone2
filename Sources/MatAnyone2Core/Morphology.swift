// SPDX-License-Identifier: GPL-3.0-or-later

extension Mask {
    /// Maximum over a (2r+1)^2 square window.
    public func dilated(radius: Int) -> Mask {
        filtered(radius: radius, combine: max, identity: 0)
    }

    /// Minimum over a (2r+1)^2 square window.
    public func eroded(radius: Int) -> Mask {
        filtered(radius: radius, combine: min, identity: 255)
    }

    /// Erode then dilate: removes structures thinner than 2r+1 pixels.
    public func opened(radius: Int) -> Mask {
        eroded(radius: radius).dilated(radius: radius)
    }

    /// Dilate then erode: fills holes and gaps narrower than 2r+1 pixels.
    public func closed(radius: Int) -> Mask {
        dilated(radius: radius).eroded(radius: radius)
    }

    /// Separable square filter: a horizontal pass, then a vertical pass. The
    /// window is clipped at the border, so a border pixel dilates inward only.
    private func filtered(radius: Int, combine: (UInt8, UInt8) -> UInt8, identity: UInt8) -> Mask {
        guard radius > 0 else { return self }
        var horizontal = pixels
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var v = identity
                for xx in max(0, x - radius)...min(width - 1, x + radius) {
                    v = combine(v, pixels[row + xx])
                }
                horizontal[row + x] = v
            }
        }
        var out = horizontal
        for y in 0..<height {
            for x in 0..<width {
                var v = identity
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    v = combine(v, horizontal[yy * width + x])
                }
                out[y * width + x] = v
            }
        }
        return Mask(width: width, height: height, pixels: out)
    }
}
