// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation
import MatAnyone2Core

/// The inference thread. Owns the engine, the calibration state machine and
/// the latest-frame-only mailbox. Every public method is safe to call from
/// any thread and returns without blocking; the work happens on the worker.
///
/// Invariant: fields under `// worker-only` are touched only by the worker
/// thread; everything else is guarded by `condition`.
public final class MattingWorker: @unchecked Sendable {
    public let workingWidth: Int
    public let workingHeight: Int

    private let modelsDirectory: URL
    private let store: CalibrationStore
    private let engineFactory: EngineFactory
    private let segmenter: any PersonSegmenter
    private let clock: any WorkerClock
    private let log: @Sendable (String) -> Void

    // Shared state (guarded by `condition`).
    private let condition = NSCondition()
    private var pending: FrameBuffer?
    private var pool: FrameBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var requests: [WorkerRequest] = []
    private var options: WorkerOptions
    private var computeUnits: MLComputeUnits
    private var stopping = false
    private var started = false
    private var publishedMatte: MatteResult?
    private var lastPolledFrameID: UInt64?
    private var snapshot: StatusSnapshot
    private var version: UInt32 = 0
    private var droppedFrames = 0
    // Only while tracking; earlier phases keep just the newest frame by design.
    private var countDrops = false
    private var displayLatencyMs: Double = 0
    private var overlayBytes: [UInt8] = []
    private var overlayVersion: UInt32 = 0
    private var overlayStatusLine = false

    // worker-only
    private var thread: Thread?
    private var engine: (any MattingEngine)?
    private var phase: Phase = .loadingModels
    private var errorResume: Phase = .uncalibrated
    private var errorUntilNs: UInt64 = 0
    private var countdownDeadlineNs: UInt64 = 0
    private var accumulator: PlateAccumulator?
    private var calibration = CalibrationData()
    private var autoSeedGate = AutoSeedGate()
    private var lastFrame: FrameBuffer?
    private var workingFrame: FrameBuffer
    private var preprocessor: FramePreprocessor
    private var postprocessor: Postprocessor
    private var imageTensor: [Float]
    /// Scratch copy of the props plate, converted for the engine at seed time.
    private let plateFrame: FrameBuffer
    private var matteBuffers: [[UInt8]]
    private var matteIndex = 0
    private var lastRawAlpha: [Float]?
    private var lastSeedNs: UInt64 = 0
    private var lastSeedAttemptNs: UInt64 = 0
    private var nextInferenceNs: UInt64 = 0
    private var inferenceStats = TimingStats()
    private var preprocessStats = TimingStats()
    private var postprocessStats = TimingStats()
    private var queueWaitStats = TimingStats()
    private var predictions = 0
    private var fpsWindowStartNs: UInt64 = 0
    private var fpsWindowCount = 0
    private var matteFPS: Double = 0
    private let overlayRenderer = OverlayRenderer()
    private var overlayLines: (title: String, detail: String) = ("", "")
    private var lastOverlayRenderNs: UInt64 = 0

    public init(
        modelsDirectory: URL, workingWidth: Int, workingHeight: Int,
        calibrationStore: CalibrationStore, computeUnits: MLComputeUnits,
        options: WorkerOptions, engineFactory: EngineFactory, segmenter: any PersonSegmenter,
        clock: any WorkerClock = SystemClock(), log: @escaping @Sendable (String) -> Void
    ) {
        self.modelsDirectory = modelsDirectory
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        self.store = calibrationStore
        self.computeUnits = computeUnits
        self.options = options
        self.engineFactory = engineFactory
        self.segmenter = segmenter
        self.clock = clock
        self.log = log
        workingFrame = FrameBuffer(width: workingWidth, height: workingHeight)
        preprocessor = FramePreprocessor(width: workingWidth, height: workingHeight)
        postprocessor = Postprocessor(width: workingWidth, height: workingHeight)
        postprocessor.options = options.postprocess
        imageTensor = [Float](repeating: 0, count: 3 * workingWidth * workingHeight)
        plateFrame = FrameBuffer(width: workingWidth, height: workingHeight)
        matteBuffers = (0..<3).map { _ in [UInt8](repeating: 0, count: workingWidth * workingHeight)
        }
        var initial = StatusSnapshot(phase: .loadingModels)
        initial.workingWidth = workingWidth
        initial.workingHeight = workingHeight
        snapshot = initial
    }

    // MARK: - Public API (any thread)

    public func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in run() }
        thread.name = "obs-matanyone2.worker"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops the worker and waits for it to exit.
    public func shutdown() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
        while let thread, !thread.isFinished {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// Copies one frame into the mailbox, replacing any unprocessed frame.
    /// Returns false when the frame was dropped because no buffer was free.
    public func submit(
        bgra: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, frameID: UInt64,
        captureNs: UInt64
    ) -> Bool {
        condition.lock()
        if pool == nil || poolWidth != width || poolHeight != height {
            pool = FrameBufferPool(width: width, height: height, capacity: 4)
            poolWidth = width
            poolHeight = height
            pending = nil
        }
        guard let buffer = pool?.take() else {
            if countDrops { droppedFrames += 1 }
            condition.unlock()
            return false
        }
        condition.unlock()

        buffer.copy(from: bgra, stride: stride)
        buffer.frameID = frameID
        buffer.captureNs = captureNs

        condition.lock()
        if let replaced = pending {
            if countDrops { droppedFrames += 1 }
            pool?.give(replaced)
        }
        pending = buffer
        condition.signal()
        condition.unlock()
        return true
    }

    /// The newest matte, once. nil until a matte newer than the last poll exists.
    public func pollMatte() -> MatteResult? {
        condition.lock()
        defer { condition.unlock() }
        guard let matte = publishedMatte, matte.frameID != lastPolledFrameID else { return nil }
        lastPolledFrameID = matte.frameID
        return matte
    }

    public func request(_ request: WorkerRequest) {
        condition.lock()
        requests.append(request)
        condition.signal()
        condition.unlock()
    }

    public func setOptions(_ newOptions: WorkerOptions) {
        condition.lock()
        options = newOptions
        condition.signal()
        condition.unlock()
    }

    /// Latency measured by the renderer in aligned mode, shown in the status line.
    public func setDisplayLatency(ms: Double) {
        condition.lock()
        displayLatencyMs = ms
        condition.unlock()
    }

    /// The overlay band when it changed since the previous poll. Tracking
    /// status is only rendered when `showStatusLine` is set.
    public func pollOverlay(showStatusLine: Bool, lastVersion: UInt32) -> (
        bytes: [UInt8], version: UInt32
    )? {
        condition.lock()
        defer { condition.unlock() }
        overlayStatusLine = showStatusLine
        guard overlayVersion != lastVersion, !overlayBytes.isEmpty else { return nil }
        return (overlayBytes, overlayVersion)
    }

    public func status() -> StatusSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return snapshot
    }

    public var statusVersion: UInt32 {
        condition.lock()
        defer { condition.unlock() }
        return version
    }

    // MARK: - Worker loop

    private func run() {
        autoreleasepool { loadModels() }
        // The thread lives as long as the filter and Core ML autoreleases
        // its outputs, so every iteration drains its own pool. Without it the
        // process grows by several MB per prediction until Core ML fails.
        while autoreleasepool(invoking: { runOnce() }) {}
    }

    /// One scheduling round: wait for work, then handle requests, the pending
    /// frame and timers. Returns false once the worker is asked to stop.
    private func runOnce() -> Bool {
        condition.lock()
        while !stopping && pending == nil && requests.isEmpty && !hasDeadline() {
            condition.wait()
        }
        if !stopping && pending == nil && requests.isEmpty {
            // A deadline is pending: sleep in short steps so an injected
            // clock advanced by a test is noticed promptly.
            condition.wait(until: Date(timeIntervalSinceNow: min(0.05, secondsToDeadline())))
        }
        if stopping {
            condition.unlock()
            return false
        }
        let frame = pending
        pending = nil
        let queued = requests
        requests.removeAll()
        let currentOptions = options
        condition.unlock()

        postprocessor.options = currentOptions.postprocess
        for request in queued {
            handle(request, options: currentOptions)
        }
        if let frame {
            process(frame, options: currentOptions)
        }
        tick(options: currentOptions)
        publishStatus()
        return true
    }

    /// Called with `condition` held.
    private func hasDeadline() -> Bool {
        switch phase {
        case .capturingClean, .capturingProps, .waitingForPerson, .error: return true
        case .tracking: return options.reseedIntervalSeconds > 0
        default: return false
        }
    }

    /// Called with `condition` held.
    private func secondsToDeadline() -> Double {
        let now = clock.nowNs()
        var deadline: UInt64 = now + 50_000_000
        switch phase {
        case .capturingClean, .capturingProps: deadline = countdownDeadlineNs
        case .error: deadline = errorUntilNs
        case .waitingForPerson: deadline = lastSeedAttemptNs + 1_000_000_000
        default: break
        }
        return deadline > now ? Double(deadline - now) / 1e9 : 0
    }

    private func loadModels() {
        let start = clock.nowNs()
        do {
            let engine = try engineFactory.make(modelsDirectory, computeUnits)
            guard engine.workingWidth == workingWidth && engine.workingHeight == workingHeight
            else {
                fail(
                    "Models are \(engine.workingWidth)x\(engine.workingHeight) but the manifest says \(workingWidth)x\(workingHeight)",
                    resume: .loadingModels, permanent: true)
                return
            }
            self.engine = engine
            log("models loaded in \((clock.nowNs() - start) / 1_000_000) ms")
        } catch {
            fail("Failed to load models: \(error)", resume: .loadingModels, permanent: true)
            return
        }
        do {
            if let data = try store.load(workingWidth: workingWidth, workingHeight: workingHeight) {
                calibration = data
                if data.propsMask != nil {
                    log("calibration loaded (\(data.propsRegions) prop regions)")
                    transition(to: .waitingForPerson)
                    return
                }
                if data.cleanPlate != nil {
                    transition(to: .cleanCaptured)
                    return
                }
            }
        } catch {
            log("ignoring stored calibration: \(error)")
        }
        transition(to: .uncalibrated)
    }

    // MARK: Requests

    private func handle(_ request: WorkerRequest, options: WorkerOptions) {
        switch request {
        case .captureClean:
            startCountdown(for: .capturingClean, options: options)
        case .captureProps:
            guard calibration.cleanPlate != nil else {
                fail("Capture the clean plate first", resume: phase)
                return
            }
            startCountdown(for: .capturingProps, options: options)
        case .seed:
            seed(policy: .initial, options: options)
        case .reseed:
            seed(policy: .refresh, options: options)
        case .clear:
            clearCalibration()
        case .setComputeUnits(let units):
            reloadModels(units)
        }
    }

    private func startCountdown(for target: Phase, options: WorkerOptions) {
        guard engine != nil else { return }
        countdownDeadlineNs =
            clock.nowNs() + UInt64(max(1, options.countdownSeconds)) * 1_000_000_000
        accumulator = PlateAccumulator(
            width: workingWidth, height: workingHeight, targetFrames: options.plateFrames)
        transition(to: target)
    }

    private enum SeedPolicy { case initial, refresh }

    private func seed(policy: SeedPolicy, options: WorkerOptions) {
        guard let engine else { return }
        guard let frame = lastFrame else {
            fail("No camera frame yet", resume: phase)
            return
        }
        let resume = phase == .tracking ? Phase.tracking : Phase.propsCaptured
        let propsMask: Mask
        if let stored = calibration.propsMask {
            propsMask = stored
        } else if options.allowSeedWithoutCalibration {
            propsMask = Mask(width: workingWidth, height: workingHeight)
        } else {
            fail("Capture the props plate before seeding", resume: phase)
            return
        }
        transition(to: .seeding)
        publishStatus()

        guard let soft = segmenter.personMask(in: frame) else {
            fail("No person detected. Sit in frame and press Seed.", resume: resume)
            return
        }
        let person = SeedComposer.personMask(fromSoft: soft)
        let mask: Mask
        do {
            switch policy {
            case .initial:
                mask = try SeedComposer.initialSeed(
                    person: person,
                    props: propsForSeed(
                        person: person, frame: frame, calibrated: propsMask, options: options))
            case .refresh:
                if let raw = lastRawAlpha {
                    mask = try SeedComposer.refreshSeed(
                        person: person, trackedAlpha: raw,
                        minSpeckArea: SpeckFilter.minimumArea(pixelCount: raw.count))
                } else {
                    mask = try SeedComposer.initialSeed(
                        person: person,
                        props: propsForSeed(
                            person: person, frame: frame, calibrated: propsMask, options: options))
                }
            }
        } catch SeedComposer.Failure.noPerson(let coverage) {
            fail(
                String(
                    format: "No person detected (%.1f%% coverage). Sit in frame and press Seed.",
                    coverage * 100),
                resume: resume)
            return
        } catch {
            fail("Seed failed: \(error)", resume: resume)
            return
        }

        let start = clock.nowNs()
        let how: String
        do {
            how = try plant(engine: engine, frame: frame, mask: mask)
        } catch {
            fail("Seed failed: \(error)", resume: resume)
            return
        }
        postprocessor.reset()
        lastRawAlpha = mask.seedFloats
        lastSeedNs = clock.nowNs()
        resetStats()
        log(
            String(
                format: "seeded (%@, %@) in %llu ms: person %.1f%%, current mask %.1f%%",
                policy == .initial ? "person + calibrated props" : "person + tracked props", how,
                (lastSeedNs - start) / 1_000_000, person.coverage * 100, mask.coverage * 100))
        transition(to: .tracking)
    }

    /// Hands the tracker its memory. With a props plate on file the plate
    /// with the props mask becomes the permanent seed frame, so the tracker
    /// knows what the props look like without the person in front of them,
    /// and `frame` with `mask` is added as a second memory frame. Without a
    /// plate, `frame` with `mask` is the seed. Returns a label for the log.
    private func plant(engine: any MattingEngine, frame: FrameBuffer, mask: Mask) throws -> String {
        engine.reset()
        if let plate = calibration.propsPlate, let props = calibration.propsMask,
            plate.width == frame.width, plate.height == frame.height
        {
            plateFrame.bgra = plate.bgra
            preprocessor.rgbPlanar(from: plateFrame, into: &imageTensor)
            try engine.seed(image: imageTensor, mask: props.seedFloats)
            preprocessor.rgbPlanar(from: frame, into: &imageTensor)
            try engine.addMemoryFrame(image: imageTensor, mask: mask.seedFloats)
            return "props plate + current frame"
        }
        preprocessor.rgbPlanar(from: frame, into: &imageTensor)
        try engine.seed(image: imageTensor, mask: mask.seedFloats)
        return "current frame only"
    }

    private func clearCalibration() {
        do { try store.clear() } catch { log("could not delete calibration: \(error)") }
        calibration = CalibrationData()
        accumulator = nil
        lastRawAlpha = nil
        engine?.reset()
        transition(to: .uncalibrated)
    }

    private func reloadModels(_ units: MLComputeUnits) {
        condition.lock()
        computeUnits = units
        condition.unlock()
        engine = nil
        lastRawAlpha = nil
        transition(to: .loadingModels)
        publishStatus()
        loadModels()
    }

    // MARK: Frames

    private func process(_ frame: FrameBuffer, options: WorkerOptions) {
        if lastFrame == nil {
            log("first frame received: \(frame.width)x\(frame.height)")
        }
        let working: FrameBuffer
        if frame.width == workingWidth && frame.height == workingHeight {
            working = frame
        } else {
            FramePreprocessor.downscale(frame, into: workingFrame)
            working = workingFrame
        }
        retain(frame)

        switch phase {
        case .capturingClean, .capturingProps:
            accumulate(working, options: options)
        case .tracking:
            infer(working, options: options)
        default:
            break
        }
    }

    /// Keeps the newest frame for seeding and returns the previous one to the pool.
    private func retain(_ frame: FrameBuffer) {
        let previous = lastFrame
        lastFrame = frame
        if let previous, previous !== frame {
            condition.lock()
            pool?.give(previous)
            condition.unlock()
        }
    }

    private func accumulate(_ frame: FrameBuffer, options: WorkerOptions) {
        guard var accumulator else { return }
        let now = clock.nowNs()
        // Frames arrive at 30-60 fps; start averaging close to the deadline so
        // the plate reflects the scene at the end of the countdown.
        let windowNs = UInt64(options.plateFrames) * 40_000_000 + 200_000_000
        if now + windowNs >= countdownDeadlineNs {
            _ = accumulator.add(bgra: frame.bgra, frameID: frame.frameID)
        }
        self.accumulator = accumulator
        if accumulator.isComplete || (now >= countdownDeadlineNs && accumulator.framesAdded > 0) {
            finishCapture(accumulator, options: options)
        }
    }

    private func finishCapture(_ accumulator: PlateAccumulator, options: WorkerOptions) {
        guard let plate = accumulator.result() else { return }
        self.accumulator = nil
        switch phase {
        case .capturingClean:
            calibration.cleanPlate = plate
            calibration.propsPlate = nil
            calibration.propsMask = nil
            calibration.propsRegions = 0
            calibration.capturedAt = Date()
            log("clean plate captured from \(accumulator.framesAdded) frames")
            save()
            transition(to: .cleanCaptured)
        case .capturingProps:
            guard let clean = calibration.cleanPlate else {
                fail("Capture the clean plate first", resume: .uncalibrated)
                return
            }
            let result = PropsMaskExtractor.extract(
                clean: clean, props: plate, threshold: UInt8(clamping: options.propsThreshold),
                minRegion: options.propsMinRegion)
            calibration.propsPlate = plate
            calibration.propsMask = result.mask
            calibration.propsRegions = result.regionCount
            calibration.threshold = options.propsThreshold
            calibration.minRegion = options.propsMinRegion
            calibration.capturedAt = Date()
            log(
                String(
                    format: "props plate captured from %d frames: %d regions, %.1f%% of the frame",
                    accumulator.framesAdded, result.regionCount, result.mask.coverage * 100))
            save()
            transition(to: .propsCaptured)
        default:
            break
        }
    }

    private func save() {
        do {
            try store.save(calibration, workingWidth: workingWidth, workingHeight: workingHeight)
        } catch {
            log("could not save calibration: \(error)")
        }
    }

    private func infer(_ frame: FrameBuffer, options: WorkerOptions) {
        guard let engine else { return }
        let now = clock.nowNs()
        if options.maxMatteFPS > 0 {
            if now < nextInferenceNs { return }
            nextInferenceNs = now + 1_000_000_000 / UInt64(options.maxMatteFPS)
        }
        queueWaitStats.add(Double(now &- frame.captureNs) / 1e6)

        let t0 = clock.nowNs()
        preprocessor.rgbPlanar(from: frame, into: &imageTensor)
        let t1 = clock.nowNs()
        var alpha: [Float]
        do {
            alpha = try engine.step(image: imageTensor)
        } catch {
            fail("Inference failed: \(error)", resume: .tracking)
            return
        }
        let t2 = clock.nowNs()
        lastRawAlpha = alpha
        matteIndex = (matteIndex + 1) % matteBuffers.count
        postprocessor.process(alpha: &alpha, into: &matteBuffers[matteIndex])
        let t3 = clock.nowNs()

        preprocessStats.add(Double(t1 - t0) / 1e6)
        inferenceStats.add(Double(t2 - t1) / 1e6)
        postprocessStats.add(Double(t3 - t2) / 1e6)
        predictions += 1
        countFPS(at: t3)

        let result = MatteResult(
            alpha: matteBuffers[matteIndex], width: workingWidth, height: workingHeight,
            frameID: frame.frameID, captureNs: frame.captureNs, readyNs: t3)
        condition.lock()
        publishedMatte = result
        condition.unlock()

        if predictions == 1 {
            log("first matte \(workingWidth)x\(workingHeight) ready")
        }
        if predictions % 120 == 0 || options.verboseLogging {
            log(
                String(
                    format:
                        "matte %.1f fps, preprocess %.2f ms, inference p50 %.2f p95 %.2f ms, postprocess %.2f ms, queue wait %.1f ms, dropped %d",
                    matteFPS, preprocessStats.mean, inferenceStats.p50, inferenceStats.p95,
                    postprocessStats.mean, queueWaitStats.mean, currentDroppedFrames()))
        }
    }

    private func countFPS(at now: UInt64) {
        if fpsWindowStartNs == 0 { fpsWindowStartNs = now }
        fpsWindowCount += 1
        let elapsed = now - fpsWindowStartNs
        if elapsed >= 1_000_000_000 {
            matteFPS = Double(fpsWindowCount) * 1e9 / Double(elapsed)
            fpsWindowStartNs = now
            fpsWindowCount = 0
        }
    }

    private func resetStats() {
        inferenceStats = TimingStats()
        preprocessStats = TimingStats()
        postprocessStats = TimingStats()
        queueWaitStats = TimingStats()
        fpsWindowStartNs = 0
        fpsWindowCount = 0
        matteFPS = 0
        nextInferenceNs = 0
        condition.lock()
        droppedFrames = 0
        condition.unlock()
    }

    private func currentDroppedFrames() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return droppedFrames
    }

    // MARK: Timers

    private func tick(options: WorkerOptions) {
        let now = clock.nowNs()
        switch phase {
        case .error:
            if now >= errorUntilNs {
                transition(to: errorResume)
            }
        case .capturingClean, .capturingProps:
            // Deadline passed without any frame: keep waiting for frames but
            // fall back to whatever was accumulated once something arrives.
            break
        case .waitingForPerson:
            if now >= lastSeedAttemptNs + 1_000_000_000, lastFrame != nil {
                lastSeedAttemptNs = now
                attemptAutoSeed(options: options)
            }
        case .tracking:
            if options.reseedIntervalSeconds > 0,
                now >= lastSeedNs + UInt64(options.reseedIntervalSeconds) * 1_000_000_000
            {
                seed(policy: .refresh, options: options)
            }
        default:
            break
        }
    }

    /// Like `seed(.initial)` but a missing person is not an error: stay in
    /// `waitingForPerson` and try again in a second.
    private func attemptAutoSeed(options: WorkerOptions) {
        guard let engine, let frame = lastFrame, let props = calibration.propsMask else { return }
        guard let soft = segmenter.personMask(in: frame) else { return }
        let person = SeedComposer.personMask(fromSoft: soft)
        guard autoSeedGate.admit(person) else {
            if options.verboseLogging {
                log(String(format: "auto-seed: waiting, person %.1f%%", person.coverage * 100))
            }
            return
        }
        let seedProps = propsForSeed(
            person: person, frame: frame, calibrated: props, options: options)
        guard let mask = try? SeedComposer.initialSeed(person: person, props: seedProps) else {
            if options.verboseLogging { log("auto-seed: no person yet") }
            return
        }
        let how: String
        do {
            how = try plant(engine: engine, frame: frame, mask: mask)
        } catch {
            fail("Seed failed: \(error)", resume: .waitingForPerson)
            return
        }
        postprocessor.reset()
        lastRawAlpha = mask.seedFloats
        lastSeedNs = clock.nowNs()
        resetStats()
        log(
            String(
                format: "auto-seeded (%@): person %.1f%%, current mask %.1f%%", how,
                person.coverage * 100, mask.coverage * 100))
        transition(to: .tracking)
    }

    /// The calibrated props re-located in the current frame (see
    /// `SeedComposer.liveProps`). Falls back to the calibrated mask when no
    /// clean plate exists or nothing in the frame overlaps it.
    private func propsForSeed(
        person: Mask, frame: FrameBuffer, calibrated: Mask, options: WorkerOptions
    ) -> Mask {
        guard let clean = calibration.cleanPlate, clean.width == frame.width,
            clean.height == frame.height
        else { return calibrated }
        let current = Plate(width: frame.width, height: frame.height, bgra: frame.bgra)
        let live = SeedComposer.liveProps(
            current: current, clean: clean, calibrated: calibrated, person: person,
            threshold: UInt8(clamping: options.propsThreshold), minRegion: options.propsMinRegion)
        if live.foregroundCount == 0 {
            // Never label visible props as background: without a live mask the
            // calibrated one is the safer guess for the current frame.
            log("props now: none found in the current frame, using the calibrated mask")
            return calibrated
        }
        log(
            String(
                format: "props now: %.1f%% of the frame (calibrated mask %.1f%%)",
                live.coverage * 100, calibrated.coverage * 100))
        return live
    }

    // MARK: Status

    private func transition(to newPhase: Phase) {
        guard newPhase != phase || newPhase == .error else { return }
        log("phase \(phase) -> \(newPhase)")
        phase = newPhase
        if newPhase == .waitingForPerson { autoSeedGate.reset() }
        condition.lock()
        countDrops = newPhase == .tracking
        if newPhase != .error {
            snapshot.message = ""
        }
        condition.unlock()
        publishStatus()
    }

    private func fail(_ message: String, resume: Phase, permanent: Bool = false) {
        log("error: \(message)")
        errorResume = resume == .error ? .uncalibrated : resume
        errorUntilNs = permanent ? UInt64.max : clock.nowNs() + 5_000_000_000
        condition.lock()
        snapshot.message = message
        condition.unlock()
        transition(to: .error)
        publishStatus()
    }

    private func publishStatus() {
        let now = clock.nowNs()
        condition.lock()
        var s = snapshot
        s.phase = phase
        s.countdownRemaining =
            (phase == .capturingClean || phase == .capturingProps) && countdownDeadlineNs > now
            ? Double(countdownDeadlineNs - now) / 1e9 : 0
        s.matteFPS = matteFPS
        s.inferenceP50 = inferenceStats.p50
        s.inferenceP95 = inferenceStats.p95
        s.matteAgeMs = queueWaitStats.mean + inferenceStats.mean + postprocessStats.mean
        s.alignedLatencyMs = displayLatencyMs
        s.droppedFrames = droppedFrames
        s.propsRegions = calibration.propsRegions
        let changed = s != snapshot
        let phaseChanged = s.phase != snapshot.phase
        if changed {
            snapshot = s
            version &+= 1
        }
        let wantStatusLine = overlayStatusLine
        condition.unlock()
        if changed {
            renderOverlayIfNeeded(
                s, phaseChanged: phaseChanged, showStatusLine: wantStatusLine, now: now)
        }
    }

    /// Re-renders the band when its text changed, at most ten times a second
    /// unless the phase changed.
    private func renderOverlayIfNeeded(
        _ s: StatusSnapshot, phaseChanged: Bool, showStatusLine: Bool, now: UInt64
    ) {
        if s.phase == .tracking && !showStatusLine { return }
        let lines = StatusFormatter.overlayLines(s)
        if lines == overlayLines { return }
        if !phaseChanged && now < lastOverlayRenderNs + 100_000_000 { return }
        overlayLines = lines
        lastOverlayRenderNs = now
        let bytes = overlayRenderer.render(title: lines.title, detail: lines.detail)
        condition.lock()
        overlayBytes = bytes
        overlayVersion &+= 1
        condition.unlock()
    }
}
