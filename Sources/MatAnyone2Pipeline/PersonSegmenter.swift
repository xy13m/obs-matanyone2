// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
import Foundation
import MatAnyone2Core
import Vision

/// Produces the person mask used for seeding. Injected so the worker can be
/// tested without Vision.
public protocol PersonSegmenter: AnyObject {
    /// Soft person mask (0...255) at the frame's resolution; nil when nobody
    /// is found or the request fails.
    func personMask(in frame: FrameBuffer) -> Mask?
}

/// Vision person segmentation at the `accurate` quality level.
public final class VisionPersonSegmenter: PersonSegmenter {
    public init() {}

    public func personMask(in frame: FrameBuffer) -> Mask? {
        guard let pixelBuffer = Self.makePixelBuffer(frame) else { return nil }
        let request = GeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormatType = kCVPixelFormatType_OneComponent8

        // The Vision API is async; the caller is the dedicated worker thread,
        // so blocking it until the mask is ready is the intended behaviour.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var observation: PixelBufferObservation?
        nonisolated(unsafe) let input = pixelBuffer
        Task.detached(priority: .userInitiated) {
            observation = try? await request.perform(on: input)
            semaphore.signal()
        }
        semaphore.wait()
        guard let observation, let image = try? observation.cgImage else { return nil }
        return Self.resize(image, toWidth: frame.width, height: frame.height)
    }

    private static func makePixelBuffer(_ frame: FrameBuffer) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        frame.bgra.withUnsafeBytes { src in
            for row in 0..<frame.height {
                base.advanced(by: row * stride).copyMemory(
                    from: src.baseAddress!.advanced(by: row * frame.rowBytes),
                    byteCount: frame.rowBytes)
            }
        }
        return buffer
    }

    /// Vision returns the mask at its own resolution; drawing the CGImage into
    /// a gray context of the frame size scales it with interpolation.
    private static func resize(_ image: CGImage, toWidth width: Int, height: Int) -> Mask? {
        var out = Mask(width: width, height: height)
        let drawn = out.pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? out : nil
    }
}
