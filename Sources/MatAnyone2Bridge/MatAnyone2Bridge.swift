// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation
import MatAnyone2Pipeline

/// Owns one loaded model set. The C++ module holds it as an opaque pointer.
private final class BridgeContext {
    let engine: CoreMLMattingEngine

    init?(modelsDirectory: String) {
        let url = URL(fileURLWithPath: modelsDirectory, isDirectory: true)
        guard
            let engine = try? CoreMLMattingEngine(
                modelsDirectory: url, computeUnits: .cpuAndNeuralEngine)
        else { return nil }
        self.engine = engine
    }
}

@_cdecl("ma2_create")
public func ma2Create(_ modelsDirectory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let modelsDirectory,
        let context = BridgeContext(modelsDirectory: String(cString: modelsDirectory))
    else { return nil }
    return Unmanaged.passRetained(context).toOpaque()
}

@_cdecl("ma2_destroy")
public func ma2Destroy(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<BridgeContext>.fromOpaque(context).release()
}

@_cdecl("ma2_working_width")
public func ma2WorkingWidth(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Int32(
        Unmanaged<BridgeContext>.fromOpaque(context).takeUnretainedValue().engine.workingWidth)
}

@_cdecl("ma2_working_height")
public func ma2WorkingHeight(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Int32(
        Unmanaged<BridgeContext>.fromOpaque(context).takeUnretainedValue().engine.workingHeight)
}
