// SPDX-License-Identifier: GPL-3.0-or-later

/// 8-connected component labelling. Labels start at 1; 0 is background.
public struct ConnectedComponents: Sendable {
    public let labels: [Int32]
    public let areas: [Int]

    public var count: Int { areas.count }

    public static func label(_ mask: Mask) -> ConnectedComponents {
        label(width: mask.width, height: mask.height) { mask.pixels[$0] > 0 }
    }

    /// Flood fill with an explicit stack; `isForeground` is called with the
    /// linear pixel index.
    public static func label(width: Int, height: Int, isForeground: (Int) -> Bool)
        -> ConnectedComponents
    {
        var labels = [Int32](repeating: 0, count: width * height)
        var areas: [Int] = []
        var stack: [Int] = []
        for start in 0..<labels.count where labels[start] == 0 && isForeground(start) {
            let label = Int32(areas.count + 1)
            var area = 0
            labels[start] = label
            stack.append(start)
            while let index = stack.popLast() {
                area += 1
                let x = index % width
                let y = index / width
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let n = yy * width + xx
                        if labels[n] == 0 && isForeground(n) {
                            labels[n] = label
                            stack.append(n)
                        }
                    }
                }
            }
            areas.append(area)
        }
        return ConnectedComponents(labels: labels, areas: areas)
    }

    /// True for pixels whose component is smaller than `minArea`.
    func isSmall(_ index: Int, minArea: Int) -> Bool {
        let label = labels[index]
        return label > 0 && areas[Int(label) - 1] < minArea
    }
}

extension Mask {
    public func removingComponents(smallerThan minArea: Int) -> Mask {
        let cc = ConnectedComponents.label(self)
        var out = self
        for i in out.pixels.indices where cc.isSmall(i, minArea: minArea) {
            out.pixels[i] = 0
        }
        return out
    }
}

/// Safety net on the tracker output: drops isolated islands of foreground
/// that are too small to be a person or a prop.
public enum SpeckFilter {
    /// 24 pixels at 512x288, scaling with the pixel count.
    public static func minimumArea(pixelCount: Int) -> Int {
        max(24, pixelCount * 16 / 100_000)
    }

    /// Zeroes alpha in 8-connected regions (alpha >= 0.5) smaller than `minArea`.
    /// Returns the number of regions removed.
    @discardableResult
    public static func removeSpecks(alpha: inout [Float], width: Int, height: Int, minArea: Int)
        -> Int
    {
        let cc = ConnectedComponents.label(width: width, height: height) { alpha[$0] >= 0.5 }
        let removed = cc.areas.filter { $0 < minArea }.count
        guard removed > 0 else { return 0 }
        for i in alpha.indices where cc.isSmall(i, minArea: minArea) {
            alpha[i] = 0
        }
        return removed
    }
}
