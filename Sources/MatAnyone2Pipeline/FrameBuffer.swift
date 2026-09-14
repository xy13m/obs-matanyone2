// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One BGRA frame owned by exactly one thread at a time: the render thread
/// fills it, the worker consumes it, then it returns to the pool.
public final class FrameBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Tightly packed, stride = width * 4.
    public var bgra: [UInt8]
    public var frameID: UInt64 = 0
    public var captureNs: UInt64 = 0

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bgra = [UInt8](repeating: 0, count: width * height * 4)
    }

    public var rowBytes: Int { width * 4 }

    /// Copies `height` rows of `width * 4` bytes from a strided source.
    public func copy(from source: UnsafePointer<UInt8>, stride: Int) {
        let rowBytes = self.rowBytes
        bgra.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                dst.baseAddress!.advanced(by: row * rowBytes)
                    .copyMemory(from: source.advanced(by: row * stride), byteCount: rowBytes)
            }
        }
    }
}

/// Fixed-size pool so the render thread never allocates per frame.
public final class FrameBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [FrameBuffer]

    public init(width: Int, height: Int, capacity: Int) {
        free = (0..<capacity).map { _ in FrameBuffer(width: width, height: height) }
    }

    /// nil when every buffer is in use; the caller drops the frame.
    public func take() -> FrameBuffer? {
        lock.withLock { free.popLast() }
    }

    public func give(_ buffer: FrameBuffer) {
        lock.withLock { free.append(buffer) }
    }
}
