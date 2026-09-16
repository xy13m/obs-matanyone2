// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import MatAnyone2Pipeline

struct ObjCExceptionGuardTests {
    @Test func runsTheBodyWhenNothingGoesWrong() throws {
        var ran = false
        try withObjCExceptionGuard("step") { ran = true }
        #expect(ran)
    }

    @Test func rethrowsSwiftErrorsAsPredictionFailures() {
        struct Boom: Error {}
        #expect(throws: EngineError.self) {
            try withObjCExceptionGuard("step") { throw Boom() }
        }
    }

    /// Core ML raises NSException on some failures. The guard must report it
    /// as an error the worker can recover from, not bring down the process.
    @Test func turnsObjectiveCExceptionsIntoErrors() {
        var caught: EngineError?
        do {
            try withObjCExceptionGuard("step") {
                NSException(name: .genericException, reason: "simulated", userInfo: nil).raise()
            }
        } catch let error as EngineError {
            caught = error
        } catch {}
        guard case .objcException(let what)? = caught else {
            Issue.record("expected objcException, got \(String(describing: caught))")
            return
        }
        #expect(what == "step")
    }
}
