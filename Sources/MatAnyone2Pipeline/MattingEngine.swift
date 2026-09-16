// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import CoreML
import Foundation
import MatAnyoneKitCoreML
import ObjCExceptionCatcher

/// The tracker as the worker sees it. Images are RGB planar Float in 0...1
/// with shape [3, H, W]; masks and alphas are [H * W].
public protocol MattingEngine: AnyObject {
    var workingWidth: Int { get }
    var workingHeight: Int { get }
    /// Clears the memory without reloading models.
    func reset()
    func seed(image: [Float], mask: [Float]) throws
    /// Adds a second frame with a known mask to the memory after `seed`.
    func addMemoryFrame(image: [Float], mask: [Float]) throws
    func step(image: [Float]) throws -> [Float]
}

public enum EngineError: Error, CustomStringConvertible {
    case objcException(String)
    case prediction(String)

    public var description: String {
        switch self {
        case .objcException(let what): return "Core ML exception during \(what)"
        case .prediction(let message): return message
        }
    }
}

/// MatAnyone2Kit engine driven directly, bypassing the kit's Vision seeding.
public final class CoreMLMattingEngine: MattingEngine {
    private let engine: MatAnyoneCoreMLEngine
    public let workingWidth: Int
    public let workingHeight: Int

    public init(modelsDirectory: URL, computeUnits: MLComputeUnits) throws {
        // objsummary is rank-5 matmul/reduce that the ANE compiler rejects; the
        // kit pins it to the GPU and runs it only on memory frames.
        let model = try MatAnyoneCoreML(
            modelsDir: modelsDirectory, computeUnits: computeUnits,
            unitOverrides: ["objsummary": .cpuAndGPU])
        engine = MatAnyoneCoreMLEngine(model: model)
        workingWidth = engine.W
        workingHeight = engine.H
    }

    public func reset() {
        engine.reset()
    }

    public func seed(image: [Float], mask: [Float]) throws {
        try guarded("seed") { [self] in
            _ = try engine.seed(
                image: .init(data: image, shape: [1, 3, workingHeight, workingWidth]),
                seedMask: mask, warmup: 10)
        }
    }

    public func addMemoryFrame(image: [Float], mask: [Float]) throws {
        try guarded("memory frame") { [self] in
            try engine.addMemoryFrame(
                image: .init(data: image, shape: [1, 3, workingHeight, workingWidth]), mask: mask)
        }
    }

    public func step(image: [Float]) throws -> [Float] {
        var alpha: [Float] = []
        try guarded("step") { [self] in
            alpha = try engine.step(
                image: .init(data: image, shape: [1, 3, workingHeight, workingWidth]))
        }
        return alpha
    }

    private func guarded(_ what: String, _ body: @escaping () throws -> Void) throws {
        try withObjCExceptionGuard(what, body)
    }
}

/// Runs `body` under an Objective-C exception handler; Core ML raises
/// NSException on some failures and Swift cannot catch those.
///
/// `body` is escaping on purpose. An NSException unwinds through the Swift
/// frames without running their cleanups, so the block's reference to `body`
/// is never released on that path. A non-escaping closure would trip the
/// runtime's escape check right after the exception was caught, turning a
/// recoverable prediction failure into a crash; an escaping one just leaks
/// the closure context that one time.
func withObjCExceptionGuard(_ what: String, _ body: @escaping () throws -> Void) throws {
    var thrown: Error?
    let survived = ma2_try_objc {
        do { try body() } catch { thrown = error }
    }
    if !survived { throw EngineError.objcException(what) }
    if let thrown { throw EngineError.prediction(thrown.localizedDescription) }
}

/// BGRA at working resolution to the engine's RGB planar Float tensor, and a
/// CPU downscale for the gpu_downscale = off path. Holds scratch planes so
/// the worker allocates nothing per frame.
public final class FramePreprocessor {
    public let width: Int
    public let height: Int
    // One scratch plane per channel, in memory order B, G, R, A.
    private let planes: [UnsafeMutablePointer<UInt8>]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        planes = (0..<4).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: width * height) }
    }

    deinit {
        for plane in planes { plane.deallocate() }
    }

    private func planeBuffer(_ index: Int) -> vImage_Buffer {
        vImage_Buffer(
            data: planes[index], height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: width)
    }

    /// `out` must hold 3 * width * height floats; planes are R, G, B.
    public func rgbPlanar(from frame: FrameBuffer, into out: inout [Float]) {
        precondition(frame.width == width && frame.height == height)
        precondition(out.count == 3 * width * height)
        let h = vImagePixelCount(height)
        let w = vImagePixelCount(width)
        let hw = width * height
        var pb = planeBuffer(0)
        var pg = planeBuffer(1)
        var pr = planeBuffer(2)
        var pa = planeBuffer(3)
        frame.bgra.withUnsafeMutableBufferPointer { src in
            var source = vImage_Buffer(
                data: src.baseAddress, height: h, width: w, rowBytes: width * 4)
            // The function names its outputs by position; memory order is B, G, R, A.
            vImageConvert_ARGB8888toPlanar8(
                &source, &pb, &pg, &pr, &pa, vImage_Flags(kvImageNoFlags))
        }
        out.withUnsafeMutableBufferPointer { dst in
            for (plane, index) in [(2, 0), (1, 1), (0, 2)] {
                var source = planeBuffer(plane)
                var target = vImage_Buffer(
                    data: dst.baseAddress!.advanced(by: index * hw), height: h, width: w,
                    rowBytes: width * MemoryLayout<Float>.size)
                vImageConvert_Planar8toPlanarF(
                    &source, &target, 1, 0, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    /// Area-averaging downscale of a full-resolution frame into `out`.
    public static func downscale(_ frame: FrameBuffer, into out: FrameBuffer) {
        frame.bgra.withUnsafeMutableBufferPointer { src in
            out.bgra.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(
                    data: src.baseAddress, height: vImagePixelCount(frame.height),
                    width: vImagePixelCount(frame.width), rowBytes: frame.width * 4)
                var target = vImage_Buffer(
                    data: dst.baseAddress, height: vImagePixelCount(out.height),
                    width: vImagePixelCount(out.width), rowBytes: out.width * 4)
                vImageScale_ARGB8888(
                    &source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        out.frameID = frame.frameID
        out.captureNs = frame.captureNs
    }
}
