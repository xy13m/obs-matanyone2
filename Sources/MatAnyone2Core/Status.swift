// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pipeline phase. Raw values cross the C ABI, so they are stable.
public enum Phase: Int32, Sendable, CaseIterable {
    case loadingModels = 0
    case uncalibrated = 1
    case capturingClean = 2
    case cleanCaptured = 3
    case capturingProps = 4
    case propsCaptured = 5
    case waitingForPerson = 6
    case seeding = 7
    case tracking = 8
    case error = 9
}

public struct StatusSnapshot: Equatable, Sendable {
    public var phase: Phase
    /// Seconds left in the current countdown, 0 when not counting.
    public var countdownRemaining: Double = 0
    public var matteFPS: Double = 0
    public var inferenceP50: Double = 0
    public var inferenceP95: Double = 0
    /// Age of the displayed matte relative to the displayed frame (lowest-latency mode).
    public var matteAgeMs: Double = 0
    /// Capture-to-display latency of the displayed pair (aligned mode), 0 when off.
    public var alignedLatencyMs: Double = 0
    public var droppedFrames: Int = 0
    public var propsRegions: Int = 0
    public var workingWidth: Int = 0
    public var workingHeight: Int = 0
    /// Last error, or an instruction for the current phase.
    public var message: String = ""

    public init(phase: Phase) {
        self.phase = phase
    }
}

public enum StatusFormatter {
    /// One line for the read-only status field in the properties panel.
    public static func panelText(_ s: StatusSnapshot) -> String {
        switch s.phase {
        case .tracking:
            var parts = [
                String(
                    format: "Tracking · %.1f matte fps · inference %.1f ms (p95 %.1f)",
                    s.matteFPS, s.inferenceP50, s.inferenceP95)
            ]
            if s.alignedLatencyMs > 0 {
                parts.append(String(format: "aligned +%.0f ms", s.alignedLatencyMs))
            } else {
                parts.append(String(format: "matte age %.0f ms", s.matteAgeMs))
            }
            if s.droppedFrames > 0 {
                parts.append("\(s.droppedFrames) dropped")
            }
            parts.append("\(s.workingWidth)x\(s.workingHeight)")
            return parts.joined(separator: " · ")
        case .error:
            return "Error: \(s.message)"
        default:
            let lines = overlayLines(s)
            return lines.detail.isEmpty ? lines.title : "\(lines.title). \(lines.detail)."
        }
    }

    /// Title and instruction for the on-video overlay.
    public static func overlayLines(_ s: StatusSnapshot) -> (title: String, detail: String) {
        switch s.phase {
        case .loadingModels:
            return ("Loading MatAnyone 2 models", "")
        case .uncalibrated:
            return ("Not calibrated", "Capture the clean plate first")
        case .capturingClean:
            return (
                String(format: "Capturing clean plate in %.1f s", s.countdownRemaining),
                "Leave the frame"
            )
        case .cleanCaptured:
            return ("Clean plate captured", "Put the props in place, then capture the props plate")
        case .capturingProps:
            return (
                String(format: "Capturing props plate in %.1f s", s.countdownRemaining),
                "Props in place, nobody in frame"
            )
        case .propsCaptured:
            return (
                "Props plate captured (\(s.propsRegions) regions)",
                "Sit down, then seed the tracker"
            )
        case .waitingForPerson:
            return ("Calibration loaded", "Waiting for a person to seed")
        case .seeding:
            return ("Seeding tracker", "")
        case .tracking:
            return ("Tracking", panelText(s))
        case .error:
            return ("Error", s.message)
        }
    }
}
