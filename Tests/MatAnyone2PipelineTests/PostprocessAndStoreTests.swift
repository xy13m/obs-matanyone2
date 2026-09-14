// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MatAnyone2Core
import Testing

@testable import MatAnyone2Pipeline

@Suite struct PostprocessorTests {
    private func square(size: Int, from: Int, to: Int) -> [Float] {
        var alpha = [Float](repeating: 0, count: size * size)
        for y in from..<to {
            for x in from..<to { alpha[y * size + x] = 1 }
        }
        return alpha
    }

    @Test func quantisesWithoutOptions() {
        let p = Postprocessor(width: 4, height: 1)
        p.options.speckFilterEnabled = false
        var alpha: [Float] = [0, 0.5, 1, 2]
        var matte = [UInt8](repeating: 9, count: 4)
        p.process(alpha: &alpha, into: &matte)
        #expect(matte == [0, 128, 255, 255])
    }

    @Test func erodeShrinksAndFeatherSoftens() {
        let p = Postprocessor(width: 16, height: 16)
        p.options.speckFilterEnabled = false
        var matte = [UInt8](repeating: 0, count: 256)

        p.options.edgeOffsetPixels = -2
        var alpha = square(size: 16, from: 4, to: 12)
        p.process(alpha: &alpha, into: &matte)
        #expect(matte[4 * 16 + 4] == 0)
        #expect(matte[7 * 16 + 7] == 255)

        p.options.edgeOffsetPixels = 2
        alpha = square(size: 16, from: 4, to: 12)
        p.process(alpha: &alpha, into: &matte)
        #expect(matte[3 * 16 + 3] > 0)
        #expect(matte[3 * 16 + 3] < 255)
        #expect(matte[7 * 16 + 7] == 255)
    }

    @Test func speckFilterRemovesIsolatedPixel() {
        let p = Postprocessor(width: 64, height: 64)
        var alpha = square(size: 64, from: 20, to: 40)
        alpha[0] = 1
        var matte = [UInt8](repeating: 0, count: 64 * 64)
        let timings = p.process(alpha: &alpha, into: &matte)
        #expect(matte[0] == 0)
        #expect(matte[30 * 64 + 30] == 255)
        #expect(timings.speckMs >= 0)
    }

    @Test func temporalSmoothingBlendsAndResets() {
        let p = Postprocessor(width: 2, height: 1)
        p.options.speckFilterEnabled = false
        p.options.temporalSmoothing = 0.5
        var matte = [UInt8](repeating: 0, count: 2)
        var a: [Float] = [1, 0]
        p.process(alpha: &a, into: &matte)
        var b: [Float] = [0, 0]
        p.process(alpha: &b, into: &matte)
        #expect(matte == [128, 0])
        p.reset()
        var c: [Float] = [0, 0]
        p.process(alpha: &c, into: &matte)
        #expect(matte == [0, 0])
    }
}

@Suite struct CalibrationStoreTests {
    private func temporaryStore() -> CalibrationStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-matanyone2-tests-\(UUID().uuidString)")
        return CalibrationStore(directory: dir, pluginVersion: "test")
    }

    @Test func roundTripsPlatesAndMask() throws {
        let store = temporaryStore()
        defer { try? store.clear() }
        var data = CalibrationData(propsRegions: 2, threshold: 16, minRegion: 64)
        var clean = Plate(width: 4, height: 2, fill: (b: 1, g: 2, r: 3))
        clean.bgra[0] = 200
        data.cleanPlate = clean
        data.propsPlate = Plate(width: 4, height: 2, fill: (b: 9, g: 8, r: 7))
        data.propsMask = Mask(width: 4, height: 2).fillingRect(
            x: 1, y: 0, width: 2, height: 2, value: 255)
        try store.save(data, workingWidth: 4, workingHeight: 2)

        let loaded = try store.load(workingWidth: 4, workingHeight: 2)
        #expect(loaded?.propsMask == data.propsMask)
        #expect(loaded?.cleanPlate == data.cleanPlate)
        #expect(loaded?.propsPlate == data.propsPlate)
        #expect(loaded?.propsRegions == 2)
        #expect(loaded?.threshold == 16)
    }

    @Test func rejectsOtherResolutionAndClears() throws {
        let store = temporaryStore()
        defer { try? store.clear() }
        var data = CalibrationData()
        data.propsMask = Mask(width: 4, height: 2)
        try store.save(data, workingWidth: 4, workingHeight: 2)
        #expect(throws: CalibrationStore.Error.self) {
            try store.load(workingWidth: 8, workingHeight: 4)
        }
        try store.clear()
        #expect(try store.load(workingWidth: 4, workingHeight: 2) == nil)
    }

    @Test func missingDirectoryLoadsNothing() throws {
        let store = temporaryStore()
        #expect(try store.load(workingWidth: 4, workingHeight: 2) == nil)
    }
}
