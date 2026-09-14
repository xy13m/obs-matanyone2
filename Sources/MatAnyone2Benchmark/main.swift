// SPDX-License-Identifier: GPL-3.0-or-later
//
// Elgato 4K X capture benchmark. Drives the same MattingWorker the plugin
// uses, so the numbers are the plugin's numbers: input, dropped and matte
// rates, inference percentiles and end-to-end latency. Quit OBS first so the
// benchmark can own the capture device.

import AVFoundation
import Accelerate
import CoreML
import CoreMedia
import Foundation
import MatAnyone2Core
import MatAnyone2Pipeline

struct Arguments {
    var modelsDirectory =
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/models/512x288/MatAnyone")
    var calibrationDirectory: URL?
    var captureOnly = false
    var duration = 60.0
    var computeUnits = MLComputeUnits.cpuAndNeuralEngine
    var device = "Elgato 4K X"

    static func parse(_ args: [String]) -> Arguments {
        var result = Arguments()
        var index = 0
        func value() -> String {
            index += 1
            guard index < args.count else { usage() }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--models":
                result.modelsDirectory = URL(fileURLWithPath: value(), isDirectory: true)
            case "--calibration":
                result.calibrationDirectory = URL(fileURLWithPath: value(), isDirectory: true)
            case "--capture-only": result.captureOnly = true
            case "--duration":
                guard let seconds = Double(value()) else { usage() }
                result.duration = seconds
            case "--device": result.device = value()
            case "--compute-units":
                switch value() {
                case "cpu_ane": result.computeUnits = .cpuAndNeuralEngine
                case "cpu_gpu": result.computeUnits = .cpuAndGPU
                case "all": result.computeUnits = .all
                default: usage()
                }
            default: usage()
            }
            index += 1
        }
        return result
    }

    static func usage() -> Never {
        FileHandle.standardError.write(
            Data(
                """
                usage: matanyone2-benchmark [--models DIR] [--calibration DIR] [--capture-only]
                                            [--duration SECONDS] [--compute-units cpu_ane|cpu_gpu|all]
                                            [--device NAME]

                """.utf8))
        exit(2)
    }
}

/// Shared counters; the capture queue writes, the report timer reads.
final class Statistics: @unchecked Sendable {
    private let lock = NSLock()
    var captured = 0
    var dropped = 0
    var submitted = 0
    var mattes = 0
    var endToEnd = TimingStats(capacity: 1000)
    var downscale = TimingStats(capacity: 1000)
    var lastMatteFrameID: UInt64 = 0
    let startedAt = Date()

    func with<T>(_ body: (Statistics) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

final class CameraDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    let worker: MattingWorker?
    let statistics: Statistics
    private var working: FrameBuffer?
    private var frameID: UInt64 = 0

    init(worker: MattingWorker?, statistics: Statistics) {
        self.worker = worker
        self.statistics = statistics
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        statistics.with { $0.captured += 1 }
        guard let worker else { return }
        frameID += 1
        let now = UInt64(DispatchTime.now().uptimeNanoseconds)

        // Same shape as the plugin: the worker receives a working-resolution
        // BGRA frame. The plugin downscales on the GPU; here vImage does it.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        if working == nil {
            working = FrameBuffer(width: worker.workingWidth, height: worker.workingHeight)
        }
        guard let working else { return }

        let t0 = DispatchTime.now().uptimeNanoseconds
        var source = vImage_Buffer(
            data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: stride)
        working.bgra.withUnsafeMutableBufferPointer { dst in
            var target = vImage_Buffer(
                data: dst.baseAddress, height: vImagePixelCount(working.height),
                width: vImagePixelCount(working.width), rowBytes: working.rowBytes)
            vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let accepted = working.bgra.withUnsafeBufferPointer { src in
            worker.submit(
                bgra: src.baseAddress!, stride: working.rowBytes, width: working.width,
                height: working.height, frameID: frameID, captureNs: now)
        }
        statistics.with {
            $0.downscale.add(Double(t1 - t0) / 1e6)
            if accepted { $0.submitted += 1 }
        }
        if let matte = worker.pollMatte() {
            statistics.with {
                $0.mattes += 1
                $0.lastMatteFrameID = matte.frameID
                $0.endToEnd.add(Double(matte.readyNs &- matte.captureNs) / 1e6)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        statistics.with { $0.dropped += 1 }
    }
}

func ensureCameraAuthorization() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        AVCaptureDevice.requestAccess(for: .video) { result in
            granted = result
            semaphore.signal()
        }
        semaphore.wait()
        if granted { return }
        fallthrough
    default:
        fail(
            "Camera access is required. Enable it for your terminal in System Settings > Privacy & Security > Camera."
        )
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("matanyone2-benchmark: \(message)\n".utf8))
    exit(1)
}

func chooseFormat(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
    device.formats
        .flatMap { format -> [(AVCaptureDevice.Format, AVFrameRateRange)] in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { return [] }
            return format.videoSupportedFrameRateRanges
                .filter { $0.maxFrameRate >= 59.0 && $0.minFrameRate <= 61.0 }
                .map { (format, $0) }
        }
        .min { abs($0.1.maxFrameRate - 60.0) < abs($1.1.maxFrameRate - 60.0) }
}

func configureCamera(name: String, delegate: CameraDelegate) throws -> AVCaptureSession {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external], mediaType: .video, position: .unspecified)
    guard let device = discovery.devices.first(where: { $0.localizedName.contains(name) }) else {
        fail("capture device '\(name)' was not found")
    }
    guard let (format, range) = chooseFormat(for: device) else {
        fail("\(device.localizedName) has no 1920x1080 60 fps format")
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { fail("could not add the capture input") }
    session.addInput(input)

    try device.lockForConfiguration()
    device.activeFormat = format
    // Devices advertise 60 fps with a hardware-specific rational; keep it as is.
    device.activeVideoMinFrameDuration = range.minFrameDuration
    device.activeVideoMaxFrameDuration = range.minFrameDuration
    device.unlockForConfiguration()

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.setSampleBufferDelegate(
        delegate,
        queue: DispatchQueue(label: "obs-matanyone2.benchmark.capture", qos: .userInteractive))
    guard session.canAddOutput(output) else { fail("could not add the video output") }
    session.addOutput(output)
    session.commitConfiguration()

    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    print(
        String(
            format: "Using %@ at %dx%d %.3f fps", device.localizedName, dimensions.width,
            dimensions.height, 1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)))
    return session
}

// MARK: - main

let arguments = Arguments.parse(Array(CommandLine.arguments.dropFirst()))
ensureCameraAuthorization()

let statistics = Statistics()
var worker: MattingWorker?
if !arguments.captureOnly {
    guard
        let manifest = try? ModelManifest(
            contentsOf: arguments.modelsDirectory.appendingPathComponent("manifest.json"))
    else { fail("no manifest.json in \(arguments.modelsDirectory.path)") }
    let calibration =
        arguments.calibrationDirectory
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "obs-matanyone2-benchmark-\(UUID().uuidString)")
    var options = WorkerOptions()
    options.allowSeedWithoutCalibration = arguments.calibrationDirectory == nil
    let created = MattingWorker(
        modelsDirectory: arguments.modelsDirectory, workingWidth: manifest.workingWidth,
        workingHeight: manifest.workingHeight,
        calibrationStore: CalibrationStore(directory: calibration, pluginVersion: "benchmark"),
        computeUnits: arguments.computeUnits, options: options, engineFactory: .coreML,
        segmenter: VisionPersonSegmenter(), log: { print("[worker] \($0)") })
    created.start()
    worker = created
    print(
        "Models: \(arguments.modelsDirectory.path) (\(manifest.workingWidth)x\(manifest.workingHeight)), compute units: \(arguments.computeUnits.rawValue)"
    )
}

let delegate = CameraDelegate(worker: worker, statistics: statistics)
let session = try configureCamera(name: arguments.device, delegate: delegate)
session.startRunning()
print(
    arguments.captureOnly
        ? "Capture-only run for \(Int(arguments.duration)) s."
        : "Benchmark running for \(Int(arguments.duration)) s. Sit in frame, then move, turn and wave."
)

var lastReport = Date()
var lastSeedAttempt = Date.distantPast
var lastCaptured = 0
var lastMattes = 0
while Date().timeIntervalSince(statistics.startedAt) < arguments.duration {
    Thread.sleep(forTimeInterval: 0.1)
    if let worker {
        let status = worker.status()
        // Seed as soon as frames flow; retry while nobody is in frame.
        if status.phase == .uncalibrated || status.phase == .error,
            Date().timeIntervalSince(lastSeedAttempt) > 2
        {
            lastSeedAttempt = Date()
            worker.request(.seed)
        }
    }
    let now = Date()
    guard now.timeIntervalSince(lastReport) >= 2 else { continue }
    let elapsed = now.timeIntervalSince(lastReport)
    lastReport = now
    let (captured, dropped, mattes, e2e95, downscale) = statistics.with {
        ($0.captured, $0.dropped, $0.mattes, $0.endToEnd.p95, $0.downscale.mean)
    }
    let inputRate = Double(captured - lastCaptured) / elapsed
    let matteRate = Double(mattes - lastMattes) / elapsed
    lastCaptured = captured
    lastMattes = mattes
    if let worker {
        let s = worker.status()
        print(
            String(
                format:
                    "input %.1f fps | dropped %d | matte %.1f fps (worker %.1f) | inference p50 %.2f p95 %.2f ms | end-to-end p95 %.1f ms | downscale %.2f ms | %@",
                inputRate, dropped, matteRate, s.matteFPS, s.inferenceP50, s.inferenceP95, e2e95,
                downscale, StatusFormatter.panelText(s)))
    } else {
        print(String(format: "input %.1f fps | dropped %d", inputRate, dropped))
    }
    fflush(stdout)
}

session.stopRunning()
let total = statistics.with {
    ($0.captured, $0.dropped, $0.mattes, $0.endToEnd.p50, $0.endToEnd.p95)
}
let seconds = Date().timeIntervalSince(statistics.startedAt)
print(
    String(
        format:
            "summary: %.0f s, input %.1f fps, dropped %d, mattes polled %.1f fps, end-to-end p50 %.1f p95 %.1f ms",
        seconds, Double(total.0) / seconds, total.1, Double(total.2) / seconds, total.3, total.4))
if let worker {
    let s = worker.status()
    print(
        String(
            format: "worker: matte %.1f fps, inference p50 %.2f p95 %.2f ms, dropped %d, phase %@",
            s.matteFPS, s.inferenceP50, s.inferenceP95, s.droppedFrames, "\(s.phase)"))
    worker.shutdown()
}
