// SPDX-License-Identifier: GPL-3.0-or-later

/// Fixed-size ring of the last N samples with cheap percentiles. Queried a
/// couple of times per second, so sorting a copy is fine.
public struct TimingStats: Sendable {
    public let capacity: Int
    private var samples: [Double]
    private var next = 0
    public private(set) var count = 0

    public init(capacity: Int = 240) {
        self.capacity = capacity
        samples = [Double](repeating: 0, count: capacity)
    }

    public mutating func add(_ value: Double) {
        samples[next] = value
        next = (next + 1) % capacity
        count = min(count + 1, capacity)
    }

    public var p50: Double { percentile(0.5) }
    public var p95: Double { percentile(0.95) }

    public var mean: Double {
        guard count > 0 else { return 0 }
        return samples[0..<count].reduce(0, +) / Double(count)
    }

    private func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let sorted = samples[0..<count].sorted()
        return sorted[Int(Double(count - 1) * fraction)]
    }
}
