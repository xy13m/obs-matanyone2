// SPDX-License-Identifier: GPL-3.0-or-later

/// Builds the mask handed to the tracker at seed time.
public enum SeedComposer {
    /// The person must cover at least this fraction of the frame.
    public static let minimumPersonCoverage = 0.01

    public enum Failure: Error, Equatable {
        case noPerson(coverage: Double)
    }

    /// Person plus the calibrated props mask. Used when the props are known
    /// to be in their calibrated positions (first seed, start-up).
    public static func initialSeed(person: Mask, props: Mask) throws -> Mask {
        try requireCoverage(person)
        return person.union(props)
    }

    /// Person plus whatever non-person foreground the tracker currently
    /// reports. Used for manual and periodic re-seeds after props moved.
    public static func refreshSeed(person: Mask, trackedAlpha: [Float], minSpeckArea: Int) throws
        -> Mask
    {
        try requireCoverage(person)
        return person.union(
            trackedProps(person: person, trackedAlpha: trackedAlpha, minSpeckArea: minSpeckArea))
    }

    /// Tracked foreground (alpha >= 0.5, specks removed) minus the person.
    public static func trackedProps(person: Mask, trackedAlpha: [Float], minSpeckArea: Int) -> Mask
    {
        precondition(trackedAlpha.count == person.count)
        var alpha = trackedAlpha
        SpeckFilter.removeSpecks(
            alpha: &alpha, width: person.width, height: person.height, minArea: minSpeckArea)
        let tracked = Mask(
            width: person.width, height: person.height, pixels: alpha.map { $0 >= 0.5 ? 255 : 0 })
        return tracked.subtracting(person)
    }

    /// Vision's soft person mask (0...255) binarised at 0.25 and grown by one
    /// pixel so low-confidence extremities stay in the seed.
    public static func personMask(fromSoft soft: Mask) -> Mask {
        soft.thresholded(64).dilated(radius: 1)
    }

    private static func requireCoverage(_ person: Mask) throws {
        let coverage = person.coverage
        if coverage < minimumPersonCoverage {
            throw Failure.noPerson(coverage: coverage)
        }
    }
}

extension Mask {
    /// The mask as the engine expects it: 1 for foreground, 0 elsewhere.
    public var seedFloats: [Float] {
        pixels.map { $0 > 0 ? 1 : 0 }
    }
}
