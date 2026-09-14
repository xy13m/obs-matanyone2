// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The `manifest.json` written next to the exported Core ML models.
///
/// The export script records the working resolution the six models were traced
/// at. The plugin reads it to size its staging textures and masks without
/// loading the models first.
public struct ModelManifest: Decodable, Equatable, Sendable {
    public struct Model: Decodable, Equatable, Sendable {
        public let name: String
        public let path: String
    }

    public let workingWidth: Int
    public let workingHeight: Int
    public let models: [Model]

    enum CodingKeys: String, CodingKey {
        case workingWidth = "working_w"
        case workingHeight = "working_h"
        case models
    }

    /// Model names the engine expects, in the order the export script writes them.
    public static let requiredModels = [
        "encoder", "uncert", "readout", "decoder", "maskencoder", "objsummary",
    ]

    public init(workingWidth: Int, workingHeight: Int, models: [Model]) {
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        self.models = models
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// Names from `requiredModels` that the manifest does not list.
    public var missingModels: [String] {
        let present = Set(models.map(\.name))
        return Self.requiredModels.filter { !present.contains($0) }
    }
}
