// SPDX-License-Identifier: GPL-3.0-or-later

public struct PropsMaskResult: Equatable, Sendable {
    public let mask: Mask
    public let regionCount: Int
}

/// Turns the clean plate and the props plate into the props mask used for
/// seeding. Pure image processing with no assumption about where the props
/// are or whether they touch a frame edge.
public enum PropsMaskExtractor {
    public static func extract(clean: Plate, props: Plate, threshold: UInt8, minRegion: Int)
        -> PropsMaskResult
    {
        let binary = difference(clean: clean, props: props).thresholded(threshold)
        // Close fills one-pixel holes and gaps inside a prop; open then drops
        // anything thinner than three pixels, which at working resolution is
        // noise rather than a prop (a boom arm is several pixels thick).
        let cleaned = binary.closed(radius: 1).opened(radius: 1)
        let kept = cleaned.removingComponents(smallerThan: minRegion)
        let regions = ConnectedComponents.label(kept).count
        return PropsMaskResult(mask: kept.dilated(radius: 1), regionCount: regions)
    }

    /// Per-pixel maximum absolute difference over B, G and R.
    public static func difference(clean: Plate, props: Plate) -> Mask {
        precondition(clean.width == props.width && clean.height == props.height)
        var out = Mask(width: clean.width, height: clean.height)
        for i in out.pixels.indices {
            let p = i * 4
            var d = 0
            for c in 0..<3 {
                d = max(d, abs(Int(clean.bgra[p + c]) - Int(props.bgra[p + c])))
            }
            out.pixels[i] = UInt8(d)
        }
        return out
    }
}
