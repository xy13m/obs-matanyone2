// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Foundation
import MatAnyone2Core

public struct PostprocessOptions: Equatable, Sendable {
    /// Drops isolated islands smaller than `SpeckFilter.minimumArea`.
    public var speckFilterEnabled = true
    /// Weight of the previous matte, 0 = off.
    public var temporalSmoothing: Float = 0
    /// Negative erodes, positive feathers, in working-resolution pixels.
    public var edgeOffsetPixels: Float = 0

    public init() {}
}

public struct PostprocessTimings: Equatable, Sendable {
    public var speckMs: Double = 0
    public var smoothMs: Double = 0
    public var edgeMs: Double = 0
}

/// Turns the engine's float alpha into the 8-bit matte the renderer uploads.
/// Stages, in order: speck filter, temporal EMA, quantize, erode or feather.
public final class Postprocessor {
    public let width: Int
    public let height: Int
    public var options = PostprocessOptions() {
        didSet { smoother.weight = options.temporalSmoothing }
    }

    private var smoother = AlphaSmoother(weight: 0)
    private var scaled: [Float]
    private var scratch: [UInt8]
    private let minSpeckArea: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        scaled = [Float](repeating: 0, count: width * height)
        scratch = [UInt8](repeating: 0, count: width * height)
        minSpeckArea = SpeckFilter.minimumArea(pixelCount: width * height)
    }

    /// Forgets temporal state, for example after a re-seed.
    public func reset() {
        smoother.reset()
    }

    @discardableResult
    public func process(alpha: inout [Float], into matte: inout [UInt8]) -> PostprocessTimings {
        precondition(alpha.count == width * height && matte.count == width * height)
        var timings = PostprocessTimings()
        let clock = ContinuousClock()

        if options.speckFilterEnabled {
            let t = clock.now
            SpeckFilter.removeSpecks(
                alpha: &alpha, width: width, height: height, minArea: minSpeckArea)
            timings.speckMs = ms(clock.now - t)
        }

        let tSmooth = clock.now
        smoother.apply(&alpha)
        timings.smoothMs = ms(clock.now - tSmooth)

        vDSP.multiply(255, alpha, result: &scaled)
        vDSP.clip(scaled, to: 0...255, result: &scaled)
        vDSP.convertElements(of: scaled, to: &matte, rounding: .towardNearestInteger)

        let radius = Int(abs(options.edgeOffsetPixels).rounded())
        if radius > 0 {
            let t = clock.now
            if options.edgeOffsetPixels < 0 {
                erode(&matte, radius: radius)
            } else {
                feather(&matte, radius: radius)
            }
            timings.edgeMs = ms(clock.now - t)
        }
        return timings
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func withBuffers(
        _ matte: inout [UInt8], _ body: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error
    ) {
        let h = vImagePixelCount(height)
        let w = vImagePixelCount(width)
        let error = matte.withUnsafeMutableBufferPointer { src -> vImage_Error in
            scratch.withUnsafeMutableBufferPointer { dst -> vImage_Error in
                var source = vImage_Buffer(
                    data: src.baseAddress, height: h, width: w, rowBytes: width)
                var target = vImage_Buffer(
                    data: dst.baseAddress, height: h, width: w, rowBytes: width)
                return body(&source, &target)
            }
        }
        if error == kvImageNoError {
            swap(&matte, &scratch)
        }
    }

    /// Minimum over a (2r+1)^2 window. A zero kernel makes vImage's erode a
    /// plain minimum filter.
    private func erode(_ matte: inout [UInt8], radius: Int) {
        let size = 2 * radius + 1
        let kernel = [UInt8](repeating: 0, count: size * size)
        withBuffers(&matte) { source, target in
            vImageErode_Planar8(
                &source, &target, 0, 0, kernel, vImagePixelCount(size), vImagePixelCount(size),
                vImage_Flags(kvImageEdgeExtend))
        }
    }

    /// Tent (triangle) blur of width 2r+1; softens the edge symmetrically.
    private func feather(_ matte: inout [UInt8], radius: Int) {
        let size = UInt32(2 * radius + 1)
        withBuffers(&matte) { source, target in
            vImageTentConvolve_Planar8(
                &source, &target, nil, 0, 0, size, size, 0, vImage_Flags(kvImageEdgeExtend))
        }
    }
}
