// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation

/// Runtime settings the filter can change while the worker runs.
public struct WorkerOptions: Equatable, Sendable {
    public var countdownSeconds = 3
    public var plateFrames = 16
    public var propsThreshold = 16
    /// Minimum props region area in working-resolution pixels.
    public var propsMinRegion = 64
    /// 0 = off.
    public var reseedIntervalSeconds = 0
    /// 0 = unlimited.
    public var maxMatteFPS = 0
    public var postprocess = PostprocessOptions()
    public var verboseLogging = false
    /// Benchmark only: seed with the person alone when no calibration exists.
    public var allowSeedWithoutCalibration = false

    public init() {}
}

public enum WorkerRequest: Sendable {
    case captureClean
    case captureProps
    case seed
    case reseed
    case clear
    case setComputeUnits(MLComputeUnits)
}

/// One finished matte. `alpha` shares storage with the worker's rotating
/// buffers; it stays valid for as long as the caller holds it.
public struct MatteResult: Sendable {
    public let alpha: [UInt8]
    public let width: Int
    public let height: Int
    public let frameID: UInt64
    public let captureNs: UInt64
    public let readyNs: UInt64
}

/// Time source, injectable so tests can drive countdowns.
public protocol WorkerClock: Sendable {
    func nowNs() -> UInt64
}

public struct SystemClock: WorkerClock {
    public init() {}
    public func nowNs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds)
    }
}

public struct EngineFactory: Sendable {
    public let make: @Sendable (URL, MLComputeUnits) throws -> any MattingEngine

    public init(make: @escaping @Sendable (URL, MLComputeUnits) throws -> any MattingEngine) {
        self.make = make
    }

    public static let coreML = EngineFactory { url, units in
        try CoreMLMattingEngine(modelsDirectory: url, computeUnits: units)
    }
}
