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

    /// The props as they are now. The current frame is compared with the
    /// clean plate the same way the props plate was, the person (grown by
    /// `personMargin` so their edge and shadow are not taken for a prop) is
    /// removed, and a region is kept only when at least `minimumOverlap` of
    /// its area lies inside the calibrated props mask. A chair that rolled a
    /// little since calibration is picked up where it stands; new objects,
    /// shadows and a room-wide lighting change (one region covering
    /// everything) are not. Empty when the result is more than
    /// `maximumGrowth` times the calibrated mask; the caller then seeds with
    /// the calibrated mask. A small result is normal: a seated person hides
    /// most of the chair, and the visible props must still be labelled.
    public static func liveProps(
        current: Plate, clean: Plate, calibrated: Mask, person: Mask, threshold: UInt8,
        minRegion: Int
    ) -> Mask {
        let changed = PropsMaskExtractor.extract(
            clean: clean, props: current, threshold: threshold, minRegion: minRegion
        ).mask
        let candidates = changed.subtracting(person.dilated(radius: personMargin))
        let components = ConnectedComponents.label(candidates)
        // Labels are 1-based; 0 is background.
        var overlap = [Int](repeating: 0, count: components.count)
        for i in candidates.pixels.indices where calibrated.pixels[i] > 0 {
            let label = Int(components.labels[i]) - 1
            if label >= 0 { overlap[label] += 1 }
        }
        let keep = (0..<components.count).map { label in
            Double(overlap[label]) >= minimumOverlap * Double(components.areas[label])
        }
        var out = Mask(width: candidates.width, height: candidates.height)
        for i in candidates.pixels.indices {
            let label = Int(components.labels[i]) - 1
            if label >= 0 && keep[label] { out.pixels[i] = 255 }
        }
        if Double(out.foregroundCount) > maximumGrowth * Double(calibrated.foregroundCount) {
            return Mask(width: out.width, height: out.height)
        }
        return out
    }

    /// Fraction of a changed region that must lie inside the calibrated mask.
    public static let minimumOverlap = 0.5
    /// Live props larger than this multiple of the calibrated mask are rejected.
    public static let maximumGrowth = 1.5

    /// Pixels around the person that are never taken for a prop.
    public static let personMargin = 2

    /// Person plus whatever non-person foreground the tracker currently
    /// reports. Used for manual and periodic re-seeds after props moved.
    /// `changed` (where the current frame differs from the clean plate)
    /// limits the tracked props: the tracker likes to spread from the person
    /// into a similar-looking background right behind them, and background
    /// that looks like the clean plate cannot be a prop. Props keep a margin
    /// of `changedMargin` pixels around the changed area.
    public static func refreshSeed(
        person: Mask, trackedAlpha: [Float], minSpeckArea: Int, changed: Mask? = nil
    ) throws -> Mask {
        try requireCoverage(person)
        var props = trackedProps(
            person: person, trackedAlpha: trackedAlpha, minSpeckArea: minSpeckArea)
        if let changed {
            props = props.intersecting(changed.dilated(radius: changedMargin))
        }
        return person.union(props)
    }

    /// How far tracked props may extend beyond the area that differs from
    /// the clean plate, in working-resolution pixels.
    public static let changedMargin = 2

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

/// Decides when the automatic seed may fire. Seeding while the person is
/// still walking into the frame teaches the tracker a partial person, so the
/// gate wants two consecutive observations with enough coverage that agree.
public struct AutoSeedGate: Sendable {
    public static let minimumCoverage = 0.05
    public static let minimumOverlap = 0.85

    private var previous: Mask?

    public init() {}

    /// Records `person` and returns true when it and the previous
    /// observation both pass the coverage floor and overlap enough.
    public mutating func admit(_ person: Mask) -> Bool {
        defer { previous = person }
        guard person.coverage >= Self.minimumCoverage, let previous else { return false }
        return previous.coverage >= Self.minimumCoverage
            && previous.intersectionOverUnion(person) >= Self.minimumOverlap
    }

    public mutating func reset() {
        previous = nil
    }
}
