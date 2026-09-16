// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import MatAnyone2Core
import UniformTypeIdentifiers

/// Everything calibration produces. Plates are kept so a user can re-derive
/// the props mask with a different threshold without recapturing.
public struct CalibrationData: Equatable, Sendable {
    public var cleanPlate: Plate?
    public var propsPlate: Plate?
    public var propsMask: Mask?
    public var propsRegions: Int
    public var threshold: Int
    public var minRegion: Int
    public var capturedAt: Date?

    public init(
        cleanPlate: Plate? = nil, propsPlate: Plate? = nil, propsMask: Mask? = nil,
        propsRegions: Int = 0, threshold: Int = 16, minRegion: Int = 200, capturedAt: Date? = nil
    ) {
        self.cleanPlate = cleanPlate
        self.propsPlate = propsPlate
        self.propsMask = propsMask
        self.propsRegions = propsRegions
        self.threshold = threshold
        self.minRegion = minRegion
        self.capturedAt = capturedAt
    }
}

/// PNG plates and mask plus meta.json in one directory per filter instance.
public struct CalibrationStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case resolutionMismatch(expected: String, found: String)
        case corrupt(String)
    }

    private struct Meta: Codable {
        var workingWidth: Int
        var workingHeight: Int
        var propsRegions: Int
        var threshold: Int
        var minRegion: Int
        var capturedAt: Date?
        var pluginVersion: String
    }

    public let directory: URL
    public let pluginVersion: String

    public init(directory: URL, pluginVersion: String = "") {
        self.directory = directory
        self.pluginVersion = pluginVersion
    }

    private var metaURL: URL { directory.appendingPathComponent("meta.json") }
    private var cleanURL: URL { directory.appendingPathComponent("clean-plate.png") }
    private var propsURL: URL { directory.appendingPathComponent("props-plate.png") }
    private var maskURL: URL { directory.appendingPathComponent("props-mask.png") }

    /// nil when nothing is stored; throws when the stored resolution differs.
    public func load(workingWidth: Int, workingHeight: Int) throws -> CalibrationData? {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return nil }
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
        guard meta.workingWidth == workingWidth && meta.workingHeight == workingHeight else {
            throw Error.resolutionMismatch(
                expected: "\(workingWidth)x\(workingHeight)",
                found: "\(meta.workingWidth)x\(meta.workingHeight)")
        }
        var data = CalibrationData(
            propsRegions: meta.propsRegions, threshold: meta.threshold, minRegion: meta.minRegion,
            capturedAt: meta.capturedAt)
        data.cleanPlate = try Self.readPlate(cleanURL, width: workingWidth, height: workingHeight)
        data.propsPlate = try Self.readPlate(propsURL, width: workingWidth, height: workingHeight)
        data.propsMask = try Self.readMask(maskURL, width: workingWidth, height: workingHeight)
        return data
    }

    public func save(_ data: CalibrationData, workingWidth: Int, workingHeight: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(plate: data.cleanPlate, to: cleanURL)
        try Self.write(plate: data.propsPlate, to: propsURL)
        try Self.write(mask: data.propsMask, to: maskURL)
        let meta = Meta(
            workingWidth: workingWidth, workingHeight: workingHeight,
            propsRegions: data.propsRegions, threshold: data.threshold, minRegion: data.minRegion,
            capturedAt: data.capturedAt, pluginVersion: pluginVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: PNG

    private static let bgraInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    private static func write(plate: Plate?, to url: URL) throws {
        guard let plate else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var bytes = plate.bgra
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: plate.width, height: plate.height,
                bitsPerComponent: 8,
                bytesPerRow: plate.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bgraInfo.rawValue
            )?.makeImage()
        }
        guard let image else { throw Error.corrupt("could not encode \(url.lastPathComponent)") }
        try writePNG(image, to: url)
    }

    private static func write(mask: Mask?, to url: URL) throws {
        guard let mask else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var bytes = mask.pixels
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: mask.width, height: mask.height, bitsPerComponent: 8,
                bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        }
        guard let image else { throw Error.corrupt("could not encode \(url.lastPathComponent)") }
        try writePNG(image, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Error.corrupt("could not create \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.corrupt("could not write \(url.lastPathComponent)")
        }
    }

    private static func readImage(_ url: URL) throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Error.corrupt("could not read \(url.lastPathComponent)") }
        return image
    }

    private static func readPlate(_ url: URL, width: Int, height: Int) throws -> Plate? {
        guard let image = try readImage(url) else { return nil }
        guard image.width == width && image.height == height else {
            throw Error.resolutionMismatch(
                expected: "\(width)x\(height)", found: "\(image.width)x\(image.height)")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bgraInfo.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return Plate(width: width, height: height, bgra: bytes)
    }

    private static func readMask(_ url: URL, width: Int, height: Int) throws -> Mask? {
        guard let image = try readImage(url) else { return nil }
        guard image.width == width && image.height == height else {
            throw Error.resolutionMismatch(
                expected: "\(width)x\(height)", found: "\(image.width)x\(image.height)")
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Mask(width: width, height: height, pixels: bytes)
    }
}
