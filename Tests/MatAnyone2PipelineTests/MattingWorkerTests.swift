// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation
import MatAnyone2Core
import Testing

@testable import MatAnyone2Pipeline

private final class FakeEngine: MattingEngine, @unchecked Sendable {
    let workingWidth = 32
    let workingHeight = 16
    private let lock = NSLock()
    private var _resets = 0
    private var _seeds: [[Float]] = []
    private var _memoryFrames: [[Float]] = []
    private var _steps = 0
    private var held = false
    private var _blocked = 0
    private let gate = NSCondition()
    var alphaToReturn = [Float](repeating: 0, count: 512)

    var resets: Int { lock.withLock { _resets } }
    var seeds: [[Float]] { lock.withLock { _seeds } }
    var memoryFrames: [[Float]] { lock.withLock { _memoryFrames } }
    var steps: Int { lock.withLock { _steps } }

    func reset() { lock.withLock { _resets += 1 } }
    func seed(image: [Float], mask: [Float]) throws { lock.withLock { _seeds.append(mask) } }
    func addMemoryFrame(image: [Float], mask: [Float]) throws {
        lock.withLock { _memoryFrames.append(mask) }
    }
    /// Steps in progress that are waiting for `release()`.
    var blockedSteps: Int { gate.withLock { _blocked } }

    /// Makes `step` wait until `release()`, so a test can keep the worker busy
    /// while it submits more frames.
    func hold() { gate.withLock { held = true } }
    func release() {
        gate.lock()
        held = false
        gate.broadcast()
        gate.unlock()
    }

    func step(image: [Float]) throws -> [Float] {
        gate.lock()
        while held {
            _blocked += 1
            gate.wait()
            _blocked -= 1
        }
        gate.unlock()
        lock.withLock { _steps += 1 }
        return alphaToReturn
    }
}

private final class FakeSegmenter: PersonSegmenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _mask: Mask?
    private var _calls = 0
    var mask: Mask? {
        get { lock.withLock { _mask } }
        set { lock.withLock { _mask = newValue } }
    }
    /// How many times the worker has asked for a person mask, found or not.
    var calls: Int { lock.withLock { _calls } }
    /// Like Vision, the mask has the size of the frame it was asked about.
    func personMask(in frame: FrameBuffer) -> Mask? {
        let mask = lock.withLock {
            _calls += 1
            return _mask
        }
        guard let mask else { return nil }
        if mask.width == frame.width && mask.height == frame.height { return mask }
        var out = Mask(width: frame.width, height: frame.height)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                out[x, y] = mask[x * mask.width / frame.width, y * mask.height / frame.height]
            }
        }
        return out
    }
}

private final class FakeClock: WorkerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: UInt64 = 1_000_000_000
    func nowNs() -> UInt64 { lock.withLock { t } }
    func advance(seconds: Double) { lock.withLock { t += UInt64(seconds * 1e9) } }
}

private struct Harness {
    let engine = FakeEngine()
    let segmenter = FakeSegmenter()
    let clock = FakeClock()
    let store: CalibrationStore
    let worker: MattingWorker
    let logs = Logs()

    final class Logs: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// Test frames are 32x16, so the props region floor is lowered from the
    /// production default.
    static var defaultOptions: WorkerOptions {
        var options = WorkerOptions()
        options.propsMinRegion = 8
        // Tests drive the clock themselves; re-seed only where a test asks.
        options.reseedIntervalSeconds = 0
        return options
    }

    init(
        options: WorkerOptions = Harness.defaultOptions,
        prepareStore: ((CalibrationStore) throws -> Void)? = nil
    )
        throws
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-matanyone2-worker-\(UUID().uuidString)")
        store = CalibrationStore(directory: dir)
        try prepareStore?(store)
        let engine = self.engine
        let logs = self.logs
        worker = MattingWorker(
            modelsDirectory: dir, workingWidth: 32, workingHeight: 16, calibrationStore: store,
            computeUnits: .cpuAndNeuralEngine, options: options,
            engineFactory: EngineFactory { _, _ in engine }, segmenter: segmenter, clock: clock,
            log: { logs.append($0) })
        worker.start()
    }

    func stop() {
        worker.shutdown()
        try? store.clear()
    }

    /// A frame with the given fill and an optional brighter rectangle. `scale`
    /// multiplies the 32x16 working size, like a renderer that skips its GPU
    /// downscale; the rectangle is given in working-size pixels.
    func submit(
        id: UInt64, fill: UInt8 = 40, rect: (x: Int, y: Int, w: Int, h: Int)? = nil,
        scale: Int = 1
    ) {
        let width = 32 * scale
        let height = 16 * scale
        var bgra = [UInt8](repeating: fill, count: width * height * 4)
        for i in stride(from: 3, to: bgra.count, by: 4) { bgra[i] = 255 }
        if let rect {
            for y in rect.y * scale..<(rect.y + rect.h) * scale {
                for x in rect.x * scale..<(rect.x + rect.w) * scale {
                    let p = (y * width + x) * 4
                    bgra[p] = 200
                    bgra[p + 1] = 200
                    bgra[p + 2] = 200
                }
            }
        }
        bgra.withUnsafeBufferPointer {
            _ = worker.submit(
                bgra: $0.baseAddress!, stride: width * 4, width: width, height: height, frameID: id,
                captureNs: clock.nowNs())
        }
    }

    /// Submits a frame and waits until the worker has handled that very frame,
    /// so the next step of a test cannot replace it in the mailbox. Waiting for
    /// the ID matters: a frame left over from an earlier loop may still be
    /// queued and would otherwise be mistaken for this one. `calibrate()` counts
    /// IDs up from 1 and can reach the hundreds on a loaded machine, so tests
    /// that wait on an ID use IDs from 90_000.
    @discardableResult
    func submitAndWait(
        id: UInt64, fill: UInt8 = 40, rect: (x: Int, y: Int, w: Int, h: Int)? = nil,
        scale: Int = 1
    ) -> Bool {
        submit(id: id, fill: fill, rect: rect, scale: scale)
        return wait { worker.lastHandledFrameID == id }
    }

    /// One auto-seed attempt while waiting for a person: moves the clock past
    /// the one-second retry, offers a frame and waits until the worker has
    /// asked the segmenter. The segmenter's answer is whatever `mask` was
    /// when this was called.
    func autoSeedAttempt(id: UInt64) -> Bool {
        let before = segmenter.calls
        clock.advance(seconds: 1.5)
        submit(id: id)
        return wait { segmenter.calls > before }
    }

    func wait(timeout: Double = 3, for predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    func waitForPhase(_ phase: Phase, timeout: Double = 3) -> Bool {
        wait(timeout: timeout) { worker.status().phase == phase }
    }

    /// Runs the whole calibration: clean plate (flat), props plate (rectangle).
    func calibrate(scale: Int = 1) -> Bool {
        worker.request(.captureClean)
        guard waitForPhase(.capturingClean) else { return false }
        clock.advance(seconds: 3)
        var id: UInt64 = 1
        guard
            wait(for: {
                submit(id: id, scale: scale)
                id += 1
                return worker.status().phase == .cleanCaptured
            })
        else { return false }
        worker.request(.captureProps)
        guard waitForPhase(.capturingProps) else { return false }
        clock.advance(seconds: 3)
        return wait {
            submit(id: id, rect: (x: 20, y: 4, w: 8, h: 8), scale: scale)
            id += 1
            return worker.status().phase == .propsCaptured
        }
    }

    static let person = Mask(width: 32, height: 16).fillingRect(
        x: 0, y: 0, width: 12, height: 16, value: 255)
}

@Suite(.serialized) struct MattingWorkerTests {
    @Test func startsUncalibratedWithoutStoredCalibration() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.worker.status().workingWidth == 32)
    }

    @Test func cleanPlateCaptureCountsDownAndAverages() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        h.worker.request(.captureClean)
        #expect(h.waitForPhase(.capturingClean))
        #expect(h.worker.status().countdownRemaining > 2.5)
        #expect(h.submitAndWait(id: 1))
        #expect(h.worker.status().phase == .capturingClean)
        h.clock.advance(seconds: 3)
        var id: UInt64 = 2
        #expect(
            h.wait {
                h.submit(id: id)
                id += 1
                return h.worker.status().phase == .cleanCaptured
            })
        let stored = try h.store.load(workingWidth: 32, workingHeight: 16)
        #expect(stored?.cleanPlate?.bgra[0] == 40)
        #expect(stored?.propsMask == nil)
    }

    @Test func propsPlateProducesMaskAndSavesIt() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        let stored = try h.store.load(workingWidth: 32, workingHeight: 16)
        #expect(h.worker.status().propsRegions == 1)
        #expect(stored?.propsMask?[24, 8] == 255)
        #expect(stored?.propsMask?[0, 0] == 0)
    }

    @Test func propsBeforeCleanIsAnError() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        h.worker.request(.captureProps)
        #expect(h.waitForPhase(.error))
        #expect(h.worker.status().message.contains("clean plate"))
        h.clock.advance(seconds: 6)
        #expect(h.waitForPhase(.uncalibrated))
    }

    @Test func seedUnionsPersonAndProps() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = Harness.person
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        #expect(h.engine.resets == 1)
        let props = try #require(h.store.load(workingWidth: 32, workingHeight: 16)?.propsMask)
        // The props plate with the props mask is the permanent seed frame;
        // the current frame with person plus props is the second memory frame.
        #expect(h.engine.seeds.last == props.seedFloats)
        let expected = try SeedComposer.initialSeed(
            person: SeedComposer.personMask(fromSoft: Harness.person), props: props)
        #expect(h.engine.memoryFrames.last == expected.seedFloats)
        #expect(h.logs.all.contains { $0.contains("seeded (person + calibrated props") })
    }

    @Test func seedWithoutPersonReportsErrorAndRecovers() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = nil
        h.worker.request(.seed)
        #expect(h.waitForPhase(.error))
        #expect(h.worker.status().message.contains("No person"))
        #expect(h.engine.seeds.isEmpty)
        h.clock.advance(seconds: 6)
        #expect(h.waitForPhase(.propsCaptured))
    }

    @Test func trackingProducesMattesAndCountsDrops() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = Harness.person
        h.engine.alphaToReturn = (0..<512).map { ($0 % 32) < 12 ? 1 : 0 }
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        // Keep the worker inside a prediction while ten frames arrive; the
        // mailbox holds one, so at least eight are replaced.
        h.engine.hold()
        h.submit(id: 90_100)
        #expect(h.wait { h.engine.blockedSteps == 1 })
        for id in 90_101..<90_110 { h.submit(id: UInt64(id)) }
        h.engine.release()
        var matte: MatteResult?
        #expect(
            h.wait {
                matte = h.worker.pollMatte() ?? matte
                return matte != nil && h.engine.steps >= 1
            })
        #expect(matte?.alpha[0] == 255)
        #expect(matte?.alpha[31] == 0)
        #expect(matte?.alpha[11] == 255)
        #expect(h.worker.pollMatte() == nil || h.worker.pollMatte()?.frameID != matte?.frameID)
        #expect(h.wait { h.worker.lastHandledFrameID == 90_109 })
        #expect(h.wait { h.worker.status().droppedFrames >= 8 })
    }

    @Test func periodicReseedUsesTrackedProps() throws {
        var options = Harness.defaultOptions
        options.reseedIntervalSeconds = 10
        let h = try Harness(options: options)
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = Harness.person
        // Tracker output: person (x 0-11) plus a prop at x 26-31, every row.
        h.engine.alphaToReturn = (0..<512).map { ($0 % 32) < 12 || ($0 % 32) >= 26 ? 1 : 0 }
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        // The prop differs from the clean plate at x 26-31 in every frame; the
        // re-seed may run on whichever frame the worker saw last.
        #expect(h.submitAndWait(id: 90_200, rect: (x: 26, y: 0, w: 6, h: 16)))
        h.clock.advance(seconds: 11)
        h.submit(id: 90_201, rect: (x: 26, y: 0, w: 6, h: 16))
        // The worker calls seed(), then addMemoryFrame(), then logs; wait for
        // the last of them, or the checks below can run in between.
        #expect(h.wait { h.logs.all.contains { $0.contains("person + tracked props") } })
        #expect(h.engine.seeds.count == 2)
        #expect(h.engine.memoryFrames.count == 2)
        let second = try #require(h.engine.memoryFrames.last)
        #expect(second[26] == 1)
        #expect(second[20] == 0)
        #expect(h.logs.all.contains { $0.contains("person + tracked props") })
    }

    @Test func periodicReseedDropsTrackedBackground() throws {
        var options = Harness.defaultOptions
        options.reseedIntervalSeconds = 10
        let h = try Harness(options: options)
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = Harness.person
        // The tracker spread from the person over x 12-19, which looks exactly
        // like the clean plate; the prop at x 26-31 is real.
        h.engine.alphaToReturn = (0..<512).map { ($0 % 32) < 20 || ($0 % 32) >= 26 ? 1 : 0 }
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        #expect(h.submitAndWait(id: 90_200, rect: (x: 26, y: 0, w: 6, h: 16)))
        h.clock.advance(seconds: 11)
        h.submit(id: 90_201, rect: (x: 26, y: 0, w: 6, h: 16))
        #expect(h.wait { h.logs.all.contains { $0.contains("person + tracked props") } })
        let second = try #require(h.engine.memoryFrames.last)
        #expect(second[8 * 32 + 28] == 1)
        #expect(second[8 * 32 + 15] == 0)
        #expect(second[8 * 32 + 5] == 1)
    }

    @Test func autoSeedsAfterLoadWhenCalibrated() throws {
        let h = try Harness(prepareStore: { store in
            var data = CalibrationData(propsRegions: 1)
            data.cleanPlate = Plate(width: 32, height: 16, fill: (b: 1, g: 1, r: 1))
            data.propsMask = Mask(width: 32, height: 16).fillingRect(
                x: 24, y: 0, width: 8, height: 16, value: 255)
            try store.save(data, workingWidth: 32, workingHeight: 16)
        })
        defer { h.stop() }
        #expect(h.waitForPhase(.waitingForPerson))
        #expect(h.autoSeedAttempt(id: 1))
        #expect(h.worker.status().phase == .waitingForPerson)
        h.segmenter.mask = Harness.person
        // One observation is not enough: the gate wants two that agree. If
        // this attempt seeded, the next one would never reach the segmenter.
        #expect(h.autoSeedAttempt(id: 2))
        #expect(h.worker.status().phase == .waitingForPerson)
        #expect(h.autoSeedAttempt(id: 3))
        #expect(h.waitForPhase(.tracking))
        #expect(h.engine.seeds.count == 1)
    }

    @Test func autoSeedWaitsForAStablePerson() throws {
        let h = try Harness(prepareStore: { store in
            var data = CalibrationData(propsRegions: 1)
            data.cleanPlate = Plate(width: 32, height: 16, fill: (b: 1, g: 1, r: 1))
            data.propsMask = Mask(width: 32, height: 16).fillingRect(
                x: 24, y: 0, width: 8, height: 16, value: 255)
            try store.save(data, workingWidth: 32, workingHeight: 16)
        })
        defer { h.stop() }
        #expect(h.waitForPhase(.waitingForPerson))
        // The person walks in: a growing mask every second.
        for width in [2, 5, 8] {
            h.segmenter.mask = Mask(width: 32, height: 16).fillingRect(
                x: 0, y: 0, width: width, height: 16, value: 255)
            #expect(h.autoSeedAttempt(id: UInt64(width)))
            #expect(h.worker.status().phase == .waitingForPerson)
        }
        // Then sits still.
        h.segmenter.mask = Harness.person
        for id in [20, 21] as [UInt64] {
            #expect(h.autoSeedAttempt(id: id))
        }
        #expect(h.waitForPhase(.tracking))
        #expect(h.engine.seeds.count == 1)
    }

    @Test func seedPicksUpPropsWhereTheyAreNow() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())  // props plate: rectangle at x 20-27
        h.segmenter.mask = Harness.person
        // The prop moved two pixels to the right before the seed.
        // The worker handles requests before the pending frame in a round, so
        // the frame has to be seen before the seed is requested.
        #expect(h.submitAndWait(id: 90_300, rect: (x: 22, y: 4, w: 8, h: 8)))
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        let current = try #require(h.engine.memoryFrames.last)
        #expect(current[8 * 32 + 30] == 1)  // new position, outside the calibrated mask
        #expect(current[8 * 32 + 19] == 0)  // old position is background now
        #expect(h.logs.all.contains { $0.contains("props now") })
    }

    @Test func framesBeforeTrackingAreNotCountedAsDropped() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        for id in 1...20 { h.submit(id: UInt64(id)) }
        // Once this frame is handled, every earlier one was handled or replaced.
        #expect(h.submitAndWait(id: 90_021))
        #expect(h.worker.status().droppedFrames == 0)
    }

    @Test func clearResetsToUncalibrated() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.worker.request(.clear)
        #expect(h.waitForPhase(.uncalibrated))
        #expect(try h.store.load(workingWidth: 32, workingHeight: 16) == nil)
    }

    @Test func computeUnitsChangeReloadsAndKeepsCalibration() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.worker.request(.setComputeUnits(.cpuAndGPU))
        #expect(h.waitForPhase(.waitingForPerson))
    }

    @Test func framesLargerThanTheWorkingSizeSeedAndTrack() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate(scale: 2))
        h.segmenter.mask = Harness.person
        h.engine.alphaToReturn = (0..<512).map { ($0 % 32) < 12 ? 1 : 0 }
        // The newest submitted frame is still 64x32 here.
        #expect(h.submitAndWait(id: 90_400, rect: (x: 20, y: 4, w: 8, h: 8), scale: 2))
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        let before = h.engine.steps
        var id: UInt64 = 90_500
        #expect(
            h.wait {
                h.submit(id: id, scale: 2)
                id += 1
                return h.engine.steps > before
            })
        #expect(h.worker.pollMatte() != nil || h.wait { h.worker.pollMatte() != nil })
    }

    @Test func frameSizeChangesKeepFramesFlowing() throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(h.waitForPhase(.uncalibrated))
        #expect(h.calibrate())
        h.segmenter.mask = Harness.person
        h.engine.alphaToReturn = (0..<512).map { ($0 % 32) < 12 ? 1 : 0 }
        h.worker.request(.seed)
        #expect(h.waitForPhase(.tracking))
        var id: UInt64 = 91_000
        for _ in 0..<4 {
            for scale in [1, 2, 1, 3] {
                let before = h.engine.steps
                // Several frames per size: a buffer held across the size change
                // comes back to the new pool on the next frame, and only a
                // later submit would take it out again. The mailbox may drop
                // frames; keep submitting until three have run.
                #expect(
                    h.wait {
                        h.submit(id: id, scale: scale)
                        id += 1
                        return h.engine.steps >= before + 3
                    })
            }
        }
        #expect(h.worker.status().phase == .tracking)
    }
}
