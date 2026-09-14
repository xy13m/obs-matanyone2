// SPDX-License-Identifier: GPL-3.0-or-later

/// A BGRA image at working resolution, tightly packed.
public struct Plate: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        precondition(bgra.count == width * height * 4)
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    public init(width: Int, height: Int, fill: (b: UInt8, g: UInt8, r: UInt8)) {
        self.width = width
        self.height = height
        bgra = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra[i] = fill.b
            bgra[i + 1] = fill.g
            bgra[i + 2] = fill.r
        }
    }
}

/// Averages N distinct frames into a plate. Frames with a repeated id (the
/// same camera frame rendered twice by OBS) are skipped.
public struct PlateAccumulator: Sendable {
    public let width: Int
    public let height: Int
    public let targetFrames: Int
    public private(set) var framesAdded = 0
    private var sums: [UInt32]
    private var lastFrameID: UInt64?

    public init(width: Int, height: Int, targetFrames: Int) {
        self.width = width
        self.height = height
        self.targetFrames = max(1, targetFrames)
        sums = [UInt32](repeating: 0, count: width * height * 4)
    }

    public var isComplete: Bool { framesAdded >= targetFrames }

    /// Returns true once the target frame count is reached.
    public mutating func add(bgra: [UInt8], frameID: UInt64) -> Bool {
        precondition(bgra.count == sums.count)
        if isComplete || frameID == lastFrameID { return isComplete }
        lastFrameID = frameID
        for i in sums.indices {
            sums[i] &+= UInt32(bgra[i])
        }
        framesAdded += 1
        return isComplete
    }

    /// Rounded mean of the frames added so far; nil before the first frame.
    public func result() -> Plate? {
        guard framesAdded > 0 else { return nil }
        let n = UInt32(framesAdded)
        return Plate(width: width, height: height, bgra: sums.map { UInt8(($0 + n / 2) / n) })
    }
}
