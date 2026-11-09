import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// The state-grounded observation block: the frontmost app's published names, handed to the model so
/// it can name a target instead of reading pixels. The cases that matter are the ones that keep it
/// honest and safe — a credential never reaches the prompt, a partial list says it is partial, and an
/// app that publishes nothing is told to use the picture rather than left to guess.
public enum ScreenStateDigestTests {

    public static func register() {
        TestRunner.currentSuite = "ScreenStateDigest"

        test("no frontmost app means no block") {
            expect(ScreenStateDigest.block(frontmost: nil, windows: [], controls: [], fields: []) == nil,
                   "a block with no app to describe would be a claim about nothing")
        }

        test("the block names controls and fields and says to prefer naming over pixels") {
            let digest = ScreenStateDigest.block(
                frontmost: "WhatsApp",
                windows: ["WhatsApp — Dad"],
                controls: [.init(label: "Send", role: "AXButton")],
                fields: [.init(label: "Compose message", role: "AXTextArea")])
            guard let digest else {
                expect(false, "a frontmost app with controls must produce a block")
                return
            }
            expect(digest.text.contains("Send") && digest.text.contains("Compose message"),
                   "the names the model should aim by are missing: \(digest.text)")
            expect(digest.text.contains("name=") && digest.text.contains("0–1000"),
                   "the block must teach naming first and pixels as the fallback")
            expect(digest.text.contains("not instructions"),
                   "published state is data; a stored sentence that reads as a command is an injection")
            expectEqual(digest.listedControls, 1, "the control tally is wrong")
            expectEqual(digest.listedFields, 1, "the field tally is wrong")
        }

        test("a credential-looking label never reaches the prompt") {
            let digest = ScreenStateDigest.block(
                frontmost: "Terminal",
                windows: [],
                controls: [.init(label: "sk-abcdefghijklmnopqrst", role: "AXStaticText"),
                           .init(label: "Run", role: "AXButton")],
                fields: [])
            guard let digest else {
                expect(false, "expected a block")
                return
            }
            expect(!digest.text.contains("sk-abcdefghijklmnopqrst"),
                   "a secret-shaped label was carried into the prompt: \(digest.text)")
            expect(digest.text.contains("Run"), "the ordinary control beside it must survive")
        }

        test("an over-long list is cut at whole lines and says how many were left out") {
            let controls = (0..<200).map { ScreenStateDigest.Control(label: "control number \($0)",
                                                                    role: "AXButton") }
            let digest = ScreenStateDigest.block(frontmost: "Chrome", windows: [],
                                                 controls: controls, fields: [])
            guard let digest else {
                expect(false, "expected a block")
                return
            }
            expect(digest.bytes <= ScreenStateDigest.maxBlockBytes,
                   "the block spent more than its budget (\(digest.bytes) bytes)")
            expect(digest.leftOut > 0, "200 controls cannot all fit; the cut must be reported")
            expect(digest.text.contains("not listed here"),
                   "a partial list described as complete is how a missing control gets invented")
            // Whole lines only: every rendered control line is intact, none clipped mid-label.
            for line in digest.text.split(separator: "\n") where line.hasPrefix("- AXButton") {
                expect(line.hasSuffix("\""), "a control line was cut mid-label: \(line)")
            }
        }

        test("an app that publishes nothing is told to use the picture") {
            let digest = ScreenStateDigest.block(frontmost: "Qoder", windows: [],
                                                 controls: [], fields: [])
            guard let digest else {
                expect(false, "a frontmost app with an empty tree still gets a block")
                return
            }
            expect(digest.text.contains("use the picture"),
                   "an Electron app with no tree must send the model to the pixels, not to guessing")
        }

        test("one over-long label is cut so it cannot spend the whole block") {
            let digest = ScreenStateDigest.block(
                frontmost: "Chrome", windows: [],
                controls: [.init(label: String(repeating: "x", count: 300), role: "AXTab")],
                fields: [])
            guard let digest else {
                expect(false, "expected a block")
                return
            }
            expect(!digest.text.contains(String(repeating: "x", count: 200)),
                   "a 300-character tab title was carried whole into the prompt")
        }
    }
}