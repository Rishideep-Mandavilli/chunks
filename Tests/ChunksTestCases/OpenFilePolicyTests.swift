import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the decision behind `[DO:open_file_with:Code|notes.md]`.
///
/// This is the one verb that puts a file's contents on his screen *inside another application*, so its
/// refusals carry weight: "that file holds credentials" is a security rule, and "there is no file
/// called X" is his own typo. The failure these cases guard against is collapsing the two into one
/// sentence — a boundary that reads like a bug sends him to re-type a path he already wrote correctly,
/// and the credential rule then quietly becomes the thing he works around.
public enum OpenFilePolicyTests {

    public static func register() {
        TestRunner.currentSuite = "Open a file policy"

        test("one file, installed app: the act proceeds and the card gets the resolved path") {
            let outcome = OpenFilePolicy.decide(app: "Code", written: "~/notes.md",
                                                 resolved: .path("/Users/him/notes.md"),
                                                 appExists: true)
            expectEqual(outcome, .opens(app: "Code", path: "/Users/him/notes.md"),
                        "the path the disk found is the path the card names")
            expect(outcome.canProceed, "an allowed open is the only outcome that may proceed")
            expectEqual(OpenFilePolicy.refusal(for: outcome), "",
                        "an outcome that proceeds has no refusal to read")
        }

        test("a missing app is reported as a missing app, even when the file is also refused") {
            let outcome = OpenFilePolicy.decide(app: "Nope", written: "~/.ssh/id_ed25519",
                                                 resolved: .secret, appExists: false)
            expectEqual(outcome, .appNotInstalled("Nope"),
                        "checking the app first is the whole point: a card about credentials "
                            + "would send him to fix a file that was never the problem")
            expectEqual(OpenFilePolicy.refusal(for: outcome),
                        "Nope is not installed, so there is nothing to open the file in.",
                        "the sentence names the app, not the file")
        }

        test("a credential is refused as a credential, never as a missing file") {
            let outcome = OpenFilePolicy.decide(app: "Code", written: "~/.ssh/id_ed25519",
                                                 resolved: .secret, appExists: true)
            expectEqual(outcome, .refused(.secret), "the boundary keeps its own answer")
            let sentence = OpenFilePolicy.refusal(for: outcome)
            expect(sentence.contains("credentials"),
                   "a refusal that does not say why reads as a broken feature: \(sentence)")
            expect(!sentence.contains("no file"),
                   "the file is there; saying it is not is the collapse these cases exist to stop")
        }

        test("outside the allowed roots says outside, and names no file at all") {
            let outcome = OpenFilePolicy.decide(app: "Code", written: "/etc/hosts",
                                                 resolved: .outside, appExists: true)
            expectEqual(outcome, .refused(.outside))
            expect(OpenFilePolicy.refusal(for: outcome).contains("outside"),
                   "the reason is the folder rule, so he can name a file inside a folder that is open")
        }

        test("a payload that is not a path is not reported as a missing file") {
            let outcome = OpenFilePolicy.decide(app: "Code", written: "\t",
                                                 resolved: .notAPath, appExists: true)
            expectEqual(outcome, .refused(.notAPath))
            expectEqual(OpenFilePolicy.refusal(for: outcome), "That is not a path Chunks can open.",
                        "distinct from notFound: nothing on disk was checked, and the card must not imply it was")
        }

        test("a name that matches nothing is refused with the name he said") {
            let outcome = OpenFilePolicy.decide(app: "Code", written: "quarterly-plan.pdf",
                                                 resolved: .nothing, appExists: true)
            expectEqual(outcome, .notFound("quarterly-plan.pdf"))
            let sentence = OpenFilePolicy.refusal(for: outcome)
            expect(sentence.contains("quarterly-plan.pdf"),
                   "the refusal quotes his own words back, so he can see what was looked for: \(sentence)")
            expect(!sentence.contains("credentials"),
                   "a missing file is not a boundary, and the two sentences must stay apart")
        }

        test("two files sharing a name is a question, and the list is short enough to read") {
            let paths = ["/Users/him/Documents/notes.md",
                         "/Users/him/Downloads/notes.md",
                         "/Users/him/Desktop/notes.md",
                         "/Users/him/Documents/Old/notes.md"]
            let outcome = OpenFilePolicy.decide(app: "Code", written: "notes.md",
                                                 resolved: .ambiguous(paths), appExists: true)
            expectEqual(outcome, .ambiguous(name: "notes.md", paths: paths),
                        "nothing is chosen for him when two things answer")
            let sentence = OpenFilePolicy.refusal(for: outcome)
            expect(sentence.hasSuffix("Say which one."),
                   "an ambiguity that does not ask is indistinguishable from a refusal: \(sentence)")
            expect(sentence.split(separator: ";").count == 3,
                   "four places on a card is not a question anyone can answer: \(sentence)")
        }

        test("only an allowed open proceeds — every other answer stops the act") {
            let stopping: [OpenFilePolicy.Outcome] = [
                .ambiguous(name: "notes.md", paths: ["/a/notes.md", "/b/notes.md"]),
                .notFound("notes.md"),
                .refused(.secret), .refused(.outside), .refused(.notAPath),
                .appNotInstalled("Code"),
            ]
            expectEqual(stopping.count, 6, "the enumeration is the contract; a new case joins it")
            for outcome in stopping {
                expect(!outcome.canProceed,
                       "\(outcome) must never reach NSWorkspace — one canProceed shortcut and the "
                            + "policy is a comment")
            }
        }

        test("a path with a trailing slash still names the file it points at") {
            let outcome = OpenFilePolicy.decide(app: "Finder", written: "~/Documents/Memora/",
                                                 resolved: .ambiguous(["/Users/him/Documents/Memora"]),
                                                 appExists: true)
            expectEqual(OpenFilePolicy.lastComponent("/Users/him/Documents/Memora/"), "Memora",
                        "the question quotes the thing's own name, not the string he typed — "
                            + "a trailing slash on a card reads as a broken path")
            expect(outcome != .notFound("Memora"),
                   "two matches is an ambiguity, and a refusal that says 'there is no file called' "
                        + "about a folder he can see on screen is the opposite of what the disk said")
        }
    }
}
