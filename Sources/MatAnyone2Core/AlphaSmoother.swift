// SPDX-License-Identifier: GPL-3.0-or-later

/// Exponential moving average over consecutive mattes:
/// `alpha = weight * previous + (1 - weight) * alpha`.
public struct AlphaSmoother: Sendable {
    public var weight: Float
    private var previous: [Float]?

    public init(weight: Float) {
        self.weight = weight
    }

    public mutating func apply(_ alpha: inout [Float]) {
        guard weight > 0 else {
            previous = nil
            return
        }
        if let previous, previous.count == alpha.count {
            let keep = 1 - weight
            for i in alpha.indices {
                alpha[i] = weight * previous[i] + keep * alpha[i]
            }
        }
        previous = alpha
    }

    /// Forgets the previous matte, for example after a re-seed.
    public mutating func reset() {
        previous = nil
    }
}
