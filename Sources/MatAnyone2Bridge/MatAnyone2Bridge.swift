// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation
import MatAnyone2BridgeABI
import MatAnyone2Core
import MatAnyone2Pipeline

/// Owns one worker. The C++ module holds it as an opaque pointer.
private final class BridgeContext: @unchecked Sendable {
    let worker: MattingWorker
    let workingWidth: Int
    let workingHeight: Int
    private let lock = NSLock()
    /// The C caller reads the matte through a pointer, so the bridge keeps
    /// its own copy that stays valid until the next poll.
    private let alphaBuffer: UnsafeMutablePointer<UInt8>

    init(worker: MattingWorker, workingWidth: Int, workingHeight: Int) {
        self.worker = worker
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        alphaBuffer = .allocate(capacity: workingWidth * workingHeight)
        alphaBuffer.initialize(repeating: 0, count: workingWidth * workingHeight)
    }

    deinit {
        alphaBuffer.deallocate()
    }

    func copyMatte(_ matte: MatteResult) -> UnsafePointer<UInt8> {
        lock.lock()
        defer { lock.unlock() }
        matte.alpha.withUnsafeBufferPointer { src in
            alphaBuffer.update(
                from: src.baseAddress!, count: min(src.count, workingWidth * workingHeight))
        }
        return UnsafePointer(alphaBuffer)
    }
}

private func context(_ pointer: UnsafeMutableRawPointer?) -> BridgeContext? {
    pointer.map { Unmanaged<BridgeContext>.fromOpaque($0).takeUnretainedValue() }
}

private func computeUnits(_ raw: Int32) -> MLComputeUnits {
    switch raw {
    case Int32(MA2_COMPUTE_CPU_GPU.rawValue): return .cpuAndGPU
    case Int32(MA2_COMPUTE_ALL.rawValue): return .all
    default: return .cpuAndNeuralEngine
    }
}

/// Copies a string into a fixed-size C char array, always NUL-terminated.
private func copy(_ string: String, into raw: UnsafeMutableRawBufferPointer) {
    let bytes = Array(string.utf8.prefix(raw.count - 1))
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
}

@_cdecl("ma2_create")
public func ma2Create(
    _ options: UnsafePointer<ma2_create_options>?, _ log: ma2_log_fn?,
    _ logUser: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let options, let modelsPath = options.pointee.models_directory,
        let calibrationPath = options.pointee.calibration_directory
    else { return nil }
    let modelsDirectory = URL(fileURLWithPath: String(cString: modelsPath), isDirectory: true)
    guard
        let manifest = try? ModelManifest(
            contentsOf: modelsDirectory.appendingPathComponent("manifest.json"))
    else { return nil }
    let version = options.pointee.plugin_version.map { String(cString: $0) } ?? ""
    let store = CalibrationStore(
        directory: URL(fileURLWithPath: String(cString: calibrationPath), isDirectory: true),
        pluginVersion: version)

    nonisolated(unsafe) let user = logUser
    let logger: @Sendable (String) -> Void = { message in
        guard let log else { return }
        message.withCString { log(user, $0) }
    }
    let worker = MattingWorker(
        modelsDirectory: modelsDirectory, workingWidth: manifest.workingWidth,
        workingHeight: manifest.workingHeight, calibrationStore: store,
        computeUnits: computeUnits(options.pointee.compute_units), options: WorkerOptions(),
        engineFactory: .coreML, segmenter: VisionPersonSegmenter(), log: logger)
    worker.start()
    let context = BridgeContext(
        worker: worker, workingWidth: manifest.workingWidth, workingHeight: manifest.workingHeight)
    return Unmanaged.passRetained(context).toOpaque()
}

@_cdecl("ma2_destroy")
public func ma2Destroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<BridgeContext>.fromOpaque(pointer)
    context.takeUnretainedValue().worker.shutdown()
    context.release()
}

@_cdecl("ma2_working_width")
public func ma2WorkingWidth(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    Int32(context(pointer)?.workingWidth ?? 0)
}

@_cdecl("ma2_working_height")
public func ma2WorkingHeight(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    Int32(context(pointer)?.workingHeight ?? 0)
}

@_cdecl("ma2_set_options")
public func ma2SetOptions(
    _ pointer: UnsafeMutableRawPointer?, _ options: UnsafePointer<ma2_options>?
) {
    guard let context = context(pointer), let o = options?.pointee else { return }
    var worker = WorkerOptions()
    worker.countdownSeconds = Int(o.countdown_seconds)
    worker.plateFrames = Int(o.plate_frames)
    worker.propsThreshold = Int(o.props_threshold)
    worker.propsMinRegion = Int(o.props_min_region)
    worker.reseedIntervalSeconds = Int(o.reseed_interval_seconds)
    worker.maxMatteFPS = Int(o.max_matte_fps)
    worker.postprocess.edgeOffsetPixels = o.edge_offset_px
    worker.postprocess.temporalSmoothing = o.temporal_smoothing
    worker.postprocess.speckFilterEnabled = o.speck_filter
    worker.verboseLogging = o.verbose_logging
    context.worker.setOptions(worker)
}

@_cdecl("ma2_set_compute_units")
public func ma2SetComputeUnits(_ pointer: UnsafeMutableRawPointer?, _ units: Int32) {
    context(pointer)?.worker.request(.setComputeUnits(computeUnits(units)))
}

@_cdecl("ma2_submit_frame")
public func ma2SubmitFrame(
    _ pointer: UnsafeMutableRawPointer?, _ bgra: UnsafePointer<UInt8>?, _ stride: UInt32,
    _ width: UInt32, _ height: UInt32, _ frameID: UInt64, _ captureNs: UInt64
) -> Bool {
    guard let context = context(pointer), let bgra, width > 0, height > 0, stride >= width * 4
    else { return false }
    return context.worker.submit(
        bgra: bgra, stride: Int(stride), width: Int(width), height: Int(height), frameID: frameID,
        captureNs: captureNs)
}

@_cdecl("ma2_poll_matte")
public func ma2PollMatte(
    _ pointer: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<ma2_matte>?
) -> Bool {
    guard let context = context(pointer), let out, let matte = context.worker.pollMatte() else {
        return false
    }
    out.pointee.alpha = context.copyMatte(matte)
    out.pointee.width = UInt32(matte.width)
    out.pointee.height = UInt32(matte.height)
    out.pointee.frame_id = matte.frameID
    out.pointee.capture_ns = matte.captureNs
    out.pointee.ready_ns = matte.readyNs
    return true
}

@_cdecl("ma2_request")
public func ma2Request(_ pointer: UnsafeMutableRawPointer?, _ request: ma2_request_kind) {
    guard let context = context(pointer) else { return }
    let mapped: WorkerRequest
    switch request {
    case MA2_REQUEST_CAPTURE_CLEAN: mapped = .captureClean
    case MA2_REQUEST_CAPTURE_PROPS: mapped = .captureProps
    case MA2_REQUEST_SEED: mapped = .seed
    case MA2_REQUEST_RESEED: mapped = .reseed
    case MA2_REQUEST_CLEAR: mapped = .clear
    default: return
    }
    context.worker.request(mapped)
}

@_cdecl("ma2_get_status")
public func ma2GetStatus(
    _ pointer: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<ma2_status>?
) {
    guard let context = context(pointer), let out else { return }
    let s = context.worker.status()
    out.pointee.version = context.worker.statusVersion
    out.pointee.phase = s.phase.rawValue
    out.pointee.countdown_remaining_s = Float(s.countdownRemaining)
    out.pointee.matte_fps = Float(s.matteFPS)
    out.pointee.inference_ms_p50 = Float(s.inferenceP50)
    out.pointee.inference_ms_p95 = Float(s.inferenceP95)
    out.pointee.matte_age_ms = Float(s.matteAgeMs)
    out.pointee.aligned_latency_ms = Float(s.alignedLatencyMs)
    out.pointee.dropped_frames = UInt32(max(0, s.droppedFrames))
    out.pointee.props_regions = UInt32(max(0, s.propsRegions))
    out.pointee.working_width = UInt32(s.workingWidth)
    out.pointee.working_height = UInt32(s.workingHeight)
    out.pointee.calibrating = s.phase != .tracking
    let lines = StatusFormatter.overlayLines(s)
    withUnsafeMutableBytes(of: &out.pointee.message) { copy(s.message, into: $0) }
    withUnsafeMutableBytes(of: &out.pointee.panel_text) {
        copy(StatusFormatter.panelText(s), into: $0)
    }
    withUnsafeMutableBytes(of: &out.pointee.overlay_title) { copy(lines.title, into: $0) }
    withUnsafeMutableBytes(of: &out.pointee.overlay_detail) { copy(lines.detail, into: $0) }
}

@_cdecl("ma2_set_display_latency")
public func ma2SetDisplayLatency(_ pointer: UnsafeMutableRawPointer?, _ milliseconds: Float) {
    context(pointer)?.worker.setDisplayLatency(ms: Double(milliseconds))
}

@_cdecl("ma2_poll_overlay")
public func ma2PollOverlay(
    _ pointer: UnsafeMutableRawPointer?, _ showStatusLine: Bool,
    _ out: UnsafeMutablePointer<ma2_overlay>?
) -> Bool {
    // Overlay rendering arrives with the overlay renderer.
    false
}
