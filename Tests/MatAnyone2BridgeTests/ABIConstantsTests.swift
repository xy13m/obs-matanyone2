// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import MatAnyone2BridgeABI
import MatAnyone2Core
import Testing

@testable import MatAnyone2Bridge
@testable import MatAnyone2Pipeline

/// The C++ module compiles against MatAnyone2Bridge.h while the Swift side
/// hands it `Phase` raw values and decodes its enums, so a mismatch would
/// compile and then show the wrong phase or request in OBS.
struct ABIConstantsTests {
    /// Every `Phase` case paired with its constant in the header. The switch is
    /// exhaustive: adding a case to `Phase` fails the build here until the
    /// header and this table have it too.
    private static func headerValue(for phase: Phase) -> UInt32 {
        switch phase {
        case .loadingModels: MA2_PHASE_LOADING_MODELS.rawValue
        case .uncalibrated: MA2_PHASE_UNCALIBRATED.rawValue
        case .capturingClean: MA2_PHASE_CAPTURING_CLEAN.rawValue
        case .cleanCaptured: MA2_PHASE_CLEAN_CAPTURED.rawValue
        case .capturingProps: MA2_PHASE_CAPTURING_PROPS.rawValue
        case .propsCaptured: MA2_PHASE_PROPS_CAPTURED.rawValue
        case .waitingForPerson: MA2_PHASE_WAITING_FOR_PERSON.rawValue
        case .seeding: MA2_PHASE_SEEDING.rawValue
        case .tracking: MA2_PHASE_TRACKING.rawValue
        case .error: MA2_PHASE_ERROR.rawValue
        }
    }

    @Test(arguments: Phase.allCases)
    func phaseRawValuesMatchTheHeader(phase: Phase) {
        #expect(UInt32(phase.rawValue) == Self.headerValue(for: phase))
    }

    @Test func computeUnitConstantsMapToCoreMLComputeUnits() {
        #expect(computeUnits(Int32(MA2_COMPUTE_CPU_ANE.rawValue)) == .cpuAndNeuralEngine)
        #expect(computeUnits(Int32(MA2_COMPUTE_CPU_GPU.rawValue)) == .cpuAndGPU)
        #expect(computeUnits(Int32(MA2_COMPUTE_ALL.rawValue)) == .all)
    }

    @Test func requestConstantsMapToWorkerRequests() {
        func name(_ kind: ma2_request_kind) -> String {
            switch workerRequest(kind) {
            case .captureClean: "captureClean"
            case .captureProps: "captureProps"
            case .seed: "seed"
            case .reseed: "reseed"
            case .clear: "clear"
            case .setComputeUnits, nil: "none"
            }
        }
        #expect(name(MA2_REQUEST_CAPTURE_CLEAN) == "captureClean")
        #expect(name(MA2_REQUEST_CAPTURE_PROPS) == "captureProps")
        #expect(name(MA2_REQUEST_SEED) == "seed")
        #expect(name(MA2_REQUEST_RESEED) == "reseed")
        #expect(name(MA2_REQUEST_CLEAR) == "clear")
        #expect(name(ma2_request_kind(rawValue: 99)) == "none")
    }
}
