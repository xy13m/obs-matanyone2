// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation
import MatAnyone2Core
import Testing

@testable import MatAnyone2Pipeline

/// Runs the real Core ML models when they have been exported locally.
/// Skipped in CI, where no models exist and there is no Neural Engine.
@Suite(.serialized) struct CoreMLEngineIntegrationTests {
    static let modelsDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["MA2_MODELS_DIR"]
        let path =
            env
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/models/512x288/MatAnyone").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var modelsExist: Bool {
        FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent("manifest.json").path)
    }

    /// A synthetic scene: dark background with a bright disc, and the seed
    /// covering the disc.
    private func scene(width: Int, height: Int, centerX: Int) -> (image: [Float], mask: Mask) {
        var image = [Float](repeating: 0.2, count: 3 * width * height)
        var mask = Mask(width: width, height: height)
        let radius = height / 4
        for y in 0..<height {
            for x in 0..<width {
                let dx = x - centerX
                let dy = y - height / 2
                if dx * dx + dy * dy <= radius * radius {
                    for c in 0..<3 {
                        image[c * width * height + y * width + x] = 0.9 - Float(c) * 0.2
                    }
                    mask[x, y] = 255
                }
            }
        }
        return (image, mask)
    }

    @Test(.enabled(if: modelsExist)) func seedsResetsAndTracksOnTheNeuralEngine() throws {
        let engine = try CoreMLMattingEngine(
            modelsDirectory: Self.modelsDirectory, computeUnits: .cpuAndNeuralEngine)
        let w = engine.workingWidth
        let h = engine.workingHeight
        #expect(w == 512 && h == 288)

        let first = scene(width: w, height: h, centerX: w / 3)
        let clock = ContinuousClock()
        let seedTime = try clock.measure {
            try engine.seed(image: first.image, mask: first.mask.seedFloats)
        }
        var stepTimes: [Double] = []
        var alpha: [Float] = []
        for shift in 0..<12 {
            let frame = scene(width: w, height: h, centerX: w / 3 + shift * 4)
            let t = try clock.measure { alpha = try engine.step(image: frame.image) }
            stepTimes.append(
                Double(t.components.seconds) * 1000 + Double(t.components.attoseconds) / 1e15)
        }
        #expect(alpha.count == w * h)
        // The disc moved right by 44 px; the matte must follow it.
        let moved = scene(width: w, height: h, centerX: w / 3 + 44)
        var inside = 0
        var insideCount = 0
        var outside = 0
        var outsideCount = 0
        for i in 0..<alpha.count {
            if moved.mask.pixels[i] > 0 {
                insideCount += 1
                if alpha[i] > 0.5 { inside += 1 }
            } else {
                outsideCount += 1
                if alpha[i] > 0.5 { outside += 1 }
            }
        }
        #expect(Double(inside) / Double(insideCount) > 0.8)
        #expect(Double(outside) / Double(outsideCount) < 0.05)

        let p50 = stepTimes.sorted()[stepTimes.count / 2]
        print(
            "integration: seed \(Double(seedTime.components.seconds) * 1000 + Double(seedTime.components.attoseconds) / 1e15) ms, step p50 \(p50) ms, disc coverage \(Double(inside) / Double(insideCount))"
        )
        // Debug builds run the kit's Swift memory math unoptimised; only the
        // release build is representative.
        #if !DEBUG
            #expect(p50 < 60)
        #endif

        // Reset must not need a reload and must accept a new seed.
        engine.reset()
        let again = scene(width: w, height: h, centerX: 2 * w / 3)
        try engine.seed(image: again.image, mask: again.mask.seedFloats)
        let after = try engine.step(image: again.image)
        var hit = 0
        for i in 0..<after.count where again.mask.pixels[i] > 0 && after[i] > 0.5 { hit += 1 }
        #expect(Double(hit) / Double(again.mask.foregroundCount) > 0.8)
    }
}
