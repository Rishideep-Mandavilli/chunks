import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the reply audit — the thing that makes "which tags came out malformed" answerable
/// without watching a card in front of people.
///
/// Every case here is a shape a model has actually been photographed writing, which is the only kind
/// of case a hand-built tag cannot produce: the suite builds tags it already knows parse, so a model
/// drifting into a new grammar is invisible to it. The audit is a witness, not a second parser, so
/// these cases assert what it *reports* about the live path rather than what it decides.
public enum ReplyAuditTests {

    public static func register() {
        TestRunner.currentSuite = "Reply audit"

        test("a tool written inside the act grammar is named as that, not as a bad aim") {
            // Photographed 2026-11-01 on Gemma 4: `[ACT:DO:open_app:Chrome]`. The parser's fail-open
            // answer is right for the user — the tag shows as text — and useless for finding out, so
            // the audit has to say which grammar the model got wrong, in those words.
            let audit = ReplyAudit.audit("<SAY>Opening Chrome now.</SAY>\n[ACT:DO:open_app:Chrome]")
            expectEqual(audit.malformed.count, 1,
                        "one tag asked for something and produced nothing")
            expectEqual(audit.malformed.first?.family, "ACT",
                        "and it is the act grammar that was used")
            expect(audit.malformed.first?.reason.contains("act grammar") ?? false,
                   "the reason names the mistake, not just the refusal: \(audit.malformed.first?.reason ?? "")")
            expect(audit.malformed.first?.reason.contains("[DO:open_app:Chrome]") ?? false,
                   "and prints the tag that would have worked")
            expect(!audit.disagreesWithTheStreamer,
                   "the streamer's own unreadActTags agrees there was an unread act "
                   + "(unreadActTags=\(audit.unreadActTags))")
        }

        test("a well-formed reply is reported clean, so a clean report means something") {
            let audit = ReplyAudit.audit("<SAY>Typing it in.</SAY>\n[DO:open_app:Chrome]\n"
                + "[TYPE:368,497:search box|how to use sql]\n<SUMMARY>Typed</SUMMARY>")
            expectEqual(audit.malformed.count, 0,
                        "nothing here should be flagged: "
                        + audit.malformed.map(\.tag).joined(separator: ", "))
            expectEqual(audit.requests.count + audit.tools.count, 2,
                        "the launch and the type both came through as requests")
            expectEqual(audit.swallowed.count, 0,
                        "the summary and the speech landed where the audit can see them")
        }

        test("an unclosed tag is reported as unclosed") {
            // The `<NEXT_ACTIONS` shape that cost a reply its chips on 2026-11-01 was an unterminated
            // block; the square equivalent is the one a model produces when it runs out of tokens.
            let audit = ReplyAudit.audit("[ACT:app=Chrome name=Search")
            expectEqual(audit.malformed.count, 1,
                        "a tag with no `]` cannot have become anything")
            expect(audit.malformed.first?.reason.contains("never closed") ?? false,
                   "and the reason says so: \(audit.malformed.first?.reason ?? "")")
        }

        test("an empty block that is consumed silently is reported as swallowed") {
            // The quieter failure: the markup never reaches the card, so nothing the user reads says
            // the completion line went missing. This is the class a card can never show.
            let audit = ReplyAudit.audit("<SAY>All done.</SAY>\n<SUMMARY></SUMMARY>")
            expect(audit.swallowed.contains { $0.family == "SUMMARY" },
                   "an empty summary produces no line, and the audit says which family vanished")
            expectEqual(audit.malformed.count, 0,
                        "it is not a malformed tag — it is a swallowed one, which is why they are two lists")
        }

        test("code with angle brackets is not mistaken for a block") {
            // `#include <stdio.h>` inside a typed payload is the reason this cannot be a test for `<`.
            let audit = ReplyAudit.audit("[TYPE:1,2:box]#include <stdio.h>\nint main(void) { return 0; }")
            expect(audit.swallowed.isEmpty,
                   "no fake families were found in a C file: " + audit.swallowed.map(\.tag).joined(separator: ", "))
            expect(audit.requests.contains { $0.textToType?.contains("#include <stdio.h>") ?? false },
                   "and the program still arrived as the payload")
        }

        test("a pipe-less type tag that gathered its words is not called malformed") {
            // The deliberate double-answer in the parser: the raw tag is shown *and* the act arrives
            // from the text after it. A probe that called this malformed would be crying wolf about
            // the one shape that works, and the user would stop reading its output.
            let audit = ReplyAudit.audit("[TYPE:12,34:code]\nint x = 1;")
            expect(audit.requests.contains { $0.textToType?.contains("int x = 1;") ?? false },
                   "the words were gathered from the line after the tag")
            expectEqual(audit.malformed.count, 0,
                        "so nothing here failed: " + audit.malformed.map(\.tag).joined(separator: ", "))
        }

        test("a scroll that lost its direction is malformed with the reason the grammar gives") {
            let audit = ReplyAudit.audit("<SAY>Looking further.</SAY>\n[SCROLL:500,500:the list]")
            expectEqual(audit.malformed.count, 1, "a scroll with no direction is not a scroll")
            expect(audit.malformed.first?.reason.contains("direction") ?? false,
                   "and the audit says what it needed: \(audit.malformed.first?.reason ?? "")")
        }

        test("a file mention that is not a path is malformed rather than silently unread") {
            let audit = ReplyAudit.audit("<SAY>Reading it.</SAY>\n[READ:|what is in it]")
            expectEqual(audit.malformed.first?.family, "READ",
                        "an empty path is a tag Chunks cannot honour, and it says so")
        }
    }
}
