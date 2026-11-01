import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the first-run flow's rules — the ones a stranger walks once.
///
/// The failure these guard is a setup that cannot be finished or finishes without something to
/// answer: a step order that lets you skip the brain, a brain step that dead-ends without a key,
/// or a flow that reports itself complete while Screen Recording is still missing.
public enum FirstRunPlanTests {

    private static let none = PermissionState(microphone: false, accessibility: false,
                                              inputMonitoring: false, screenRecording: false,
                                              screenContent: false)
    private static let all = PermissionState(microphone: true, accessibility: true,
                                             inputMonitoring: true, screenRecording: true,
                                             screenContent: true)

    private static func plan(_ permissions: PermissionState, hasKey: Bool = false,
                             offline: Bool = false, finished: Bool = false) -> FirstRunPlan {
        FirstRunPlan(permissions: permissions, hasKey: hasKey, offlineBrainOn: offline,
                     finished: finished)
    }

    public static func register() {
        TestRunner.currentSuite = "First run"

        test("the flow opens on the first step and cannot be skipped ahead") {
            let fresh = plan(none)
            expectEqual(fresh.currentStep, .permissions,
                        "a stranger's first screen must be the grants, not the key field")
            let granted = plan(all)
            expectEqual(granted.currentStep, .brain,
                        "once macOS agrees, the next thing to decide is what answers")
        }

        test("no key is a tier, not a dead end") {
            let offline = plan(all, offline: true)
            expect(offline.isComplete(.brain),
                   "the local switch must complete the brain step exactly as a key does — "
                       + "4.3's bar is that a buyer without a key leaves with a working assistant")
            expect(!plan(all).isComplete(.brain),
                   "and it must not read as complete with neither: that is the dead end")
        }

        test("the flow is only complete when every step is, including Done") {
            let everythingButDone = plan(all, hasKey: true)
            expect(!everythingButDone.isComplete,
                   "a setup that closes itself before the user said so is a window that vanishes")
            expect(everythingButDone.currentStep == .finish,
                   "the last step is where the login choice lives")
            expect(plan(all, hasKey: true, finished: true).isComplete,
                   "Done is the only thing that finishes the finish step")
        }

        test("revoked grants reopen the flow at the step they broke") {
            var hadKey = plan(all, hasKey: true, finished: true)
            expect(hadKey.isComplete, "the finished state starts complete")
            hadKey.permissions = PermissionState(microphone: true, accessibility: true,
                                                 inputMonitoring: true, screenRecording: false,
                                                 screenContent: false)
            expect(!hadKey.isComplete,
                   "a revoked Screen Recording must reopen the flow, not keep saying it is done")
            expectEqual(hadKey.currentStep, .permissions,
                        "and it must reopen on the grants step, where the fix is")
        }

        test("the sentences a stranger reads are the ones the tests can see") {
            expect(FirstRunPlan.keySentence.contains("aistudio.google.com/apikey"),
                   "the key step must say where the key comes from in one sentence")
            expect(FirstRunPlan.keySentence.lowercased().contains("keychain"),
                   "and where it goes — a credential field without that answer is a trust question")
            expect(FirstRunPlan.offlineSentence.lowercased().contains("nothing leaves"),
                   "the no-key tier must be stated as a tier, in the same register")
            expect(FirstRunPlan.restartSentence.contains("next launch"),
                   "the restart trap — ticked but still Needed — has to be said before it is hit")
        }
    }
}
