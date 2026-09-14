// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import MatAnyone2Core

@Suite struct ModelManifestTests {
    private let landscape = """
        {
          "working_h": 288,
          "working_w": 512,
          "compute_units": "CPU_AND_NE",
          "models": [
            {"name": "encoder", "path": "models/encoder.mlpackage"},
            {"name": "uncert", "path": "models/uncert.mlpackage"},
            {"name": "readout", "path": "models/readout.mlpackage"},
            {"name": "decoder", "path": "models/decoder.mlpackage"},
            {"name": "maskencoder", "path": "models/maskencoder.mlpackage"},
            {"name": "objsummary", "path": "models/objsummary.mlpackage"}
          ]
        }
        """

    @Test func decodesWorkingResolutionAndModels() throws {
        let manifest = try ModelManifest(data: Data(landscape.utf8))
        #expect(manifest.workingWidth == 512)
        #expect(manifest.workingHeight == 288)
        #expect(manifest.models.map(\.name) == ModelManifest.requiredModels)
        #expect(manifest.missingModels.isEmpty)
    }

    @Test func reportsMissingModels() throws {
        let partial = """
            {"working_h": 288, "working_w": 512,
             "models": [{"name": "encoder", "path": "models/encoder.mlpackage"}]}
            """
        let manifest = try ModelManifest(data: Data(partial.utf8))
        #expect(
            manifest.missingModels == ["uncert", "readout", "decoder", "maskencoder", "objsummary"])
    }

    @Test func rejectsManifestWithoutResolution() {
        let broken = Data(#"{"models": []}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ModelManifest(data: broken)
        }
    }
}
