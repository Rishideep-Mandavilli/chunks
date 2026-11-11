import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// The Chrome bridge's pure half: the wire framing, the query resolver, the snapshot budgets, the web
/// tool verbs and their consent rules, and the web state block. The socket and the DOM are shell work;
/// everything that decides *what* is named and *whether* it is asked about lives here and is tested.
public enum WebBridgeTests {

    public static func register() {
        TestRunner.currentSuite = "WebBridge"

        test("a command and reply round-trip through the native-messaging frame") {
            let command = BridgeCommand(id: "a1", action: .click, query: "#3", text: "Play")
            guard let frame = WebBridgeFraming.encode(command) else {
                expect(false, "encoding a command must succeed"); return
            }
            expectEqual(frame.count, 4 + (try! JSONEncoder().encode(command)).count,
                        "the frame is a 4-byte length plus the JSON")
            guard let (decoded, consumed) = WebBridgeFraming.decode(BridgeCommand.self, from: frame) else {
                expect(false, "a whole frame must decode"); return
            }
            expectEqual(decoded, command, "what crosses the wire is what was sent")
            expectEqual(consumed, frame.count, "the whole frame is consumed")
        }

        test("the read loop decodes consecutive frames after removeFirst without trapping") {
            // The 22:12 crash: decode used absolute 4..<4+size on a buffer whose startIndex had
            // shifted after removeFirst, trapping in Data.subdata. Mirror the ingest loop exactly.
            let a = BridgeReply(id: "one", ok: true, message: "first")
            let b = BridgeReply(id: "two", ok: true, message: "second")
            guard let fa = WebBridgeFraming.encode(a), let fb = WebBridgeFraming.encode(b) else {
                expect(false, "encoding must succeed"); return
            }
            var buffer = Data([0xAA, 0xBB])           // leading garbage offset
            buffer.append(fa); buffer.append(fb)
            buffer.removeFirst(2)                     // shift startIndex like the read loop
            guard let (first, c1) = WebBridgeFraming.decode(BridgeReply.self, from: buffer) else {
                expect(false, "first frame must decode from a shifted buffer"); return
            }
            expectEqual(first.id, "one", "the shifted buffer decoded the wrong frame")
            buffer.removeFirst(c1)
            guard let (second, _) = WebBridgeFraming.decode(BridgeReply.self, from: buffer) else {
                expect(false, "second frame must decode after removeFirst"); return
            }
            expectEqual(second.id, "two", "consecutive frames must both survive the read loop")
        }

        test("a partial frame decodes to nothing rather than guessing") {
            let command = BridgeCommand(id: "a1", action: .snapshot)
            guard let frame = WebBridgeFraming.encode(command) else {
                expect(false, "encoding must succeed"); return
            }
            expect(WebBridgeFraming.decode(BridgeCommand.self, from: frame.prefix(3)) == nil,
                   "fewer than four bytes is not a length")
            expect(WebBridgeFraming.decode(BridgeCommand.self, from: frame.dropLast()) == nil,
                   "a truncated body must wait for the rest, not decode half")
        }

        test("an absurd length is refused, not allocated") {
            var huge = Data([0xFF, 0xFF, 0xFF, 0x7F])   // ~2 GB
            huge.append(Data(repeating: 0, count: 16))
            expect(WebBridgeFraming.decode(BridgeReply.self, from: huge) == nil,
                   "a hostile length must not make the app reserve memory")
        }

        test("a query names one control by index or by words, and two answers is a refusal") {
            let elements = [
                WebElement(index: 0, text: "Search", role: "button", selector: "#0", editable: false),
                WebElement(index: 1, text: "comedy scenes", role: "a", selector: "#1", editable: false),
                WebElement(index: 2, text: "comedy scenes", role: "a", selector: "#2", editable: false),
                WebElement(index: 3, text: "Search", role: "input", selector: "#3", editable: true),
            ]
            expectEqual(WebQuery.resolve("#1", in: elements), .one(elements[1]),
                        "an index names exactly the control the snapshot listed")
            expectEqual(WebQuery.resolve("comedy scenes", in: elements), .ambiguous([elements[1], elements[2]]),
                        "two controls with the same words is a refusal, never a coin toss")
            expectEqual(WebQuery.resolve("Search", in: elements), .ambiguous([elements[0], elements[3]]),
                        "a word two controls answer is ambiguous even across roles")
            expectEqual(WebQuery.resolve("nothing here", in: elements), .none,
                        "a name the page does not publish resolves to nothing")
        }

        test("a snapshot is budgeted and says how many controls it left out") {
            let many = (0..<200).map {
                WebElement(index: $0, text: String(repeating: "x", count: 200), role: "a",
                           selector: "#\($0)", editable: false)
            }
            let snap = PageSnapshot(url: "https://example.com", title: "t",
                                    text: String(repeating: "word ", count: 2000), elements: many)
            let cut = snap.budgeted()
            expect(cut.elements.count <= PageSnapshot.maxElements, "the element list is capped")
            expect(cut.text.count <= PageSnapshot.maxTextCharacters + 2, "the body text is capped")
            expect(cut.elements.allSatisfy { $0.text.count <= PageSnapshot.maxElementTextCharacters },
                   "one long label cannot spend the block")
            expect(snap.modelBlock().contains("more controls not listed"),
                   "a partial list must say it is partial")
        }

        test("the web verbs parse, and a bad url or empty query is refused") {
            expectEqual(DoRequest.parse("web_open:youtube.com"), .webOpen(url: "https://youtube.com"),
                        "web_open normalizes like open_url")
            expect(DoRequest.parse("web_open:javascript:alert(1)") == nil,
                   "a non-http scheme is refused at the web door too")
            expectEqual(DoRequest.parse("web_click:#3"), .webClick(query: "#3"), "an index click parses")
            expectEqual(DoRequest.parse("web_type:#3|good night"), .webType(query: "#3", text: "good night"),
                        "a type carries its payload")
            expect(DoRequest.parse("web_type:#3") == nil, "a type with no text is not an act")
            expect(DoRequest.parse("web_click:") == nil, "an empty query is refused")
        }

        test("a web click or type is always asked; navigating is routine") {
            expect(ToolLayer.alwaysAsks(.webClick(query: "Send")),
                   "a click on a page is a press and is asked even with asking off")
            expect(ToolLayer.alwaysAsks(.webType(query: "#3", text: "hi")),
                   "keystrokes into a page are asked even with asking off")
            expect(!ToolLayer.alwaysAsks(.webOpen(url: "https://youtube.com")),
                   "navigating is routine, like open_url")
            expect(ToolLayer.effect(of: .webClick(query: "x")) == .changesSystemState,
                   "a web act changes the machine, so it is never a free read")
        }

        test("the web card question names the effect and stays readable") {
            expect(ToolLayer.question(for: .webClick(query: "Play")).contains("Play"),
                   "the card quotes the words being clicked")
            expect(ToolLayer.question(for: .webType(query: "#3", text: "hello")).contains("5 characters"),
                   "a type names its payload size, not six thousand characters on a card")
            expect(ToolLayer.question(for: .webOpen(url: "https://youtube.com")).contains("youtube.com"),
                   "the card shows the host, not the scheme")
        }

        test("the web state block lists names, redacts credentials, and teaches the web verbs") {
            let snap = PageSnapshot(url: "https://example.com", title: "Example",
                                    text: "body", elements: [
                WebElement(index: 0, text: "Search", role: "input", selector: "#0", editable: true),
                WebElement(index: 1, text: "sk-abcdefghijklmnopqrstuvwxyz123456", role: "a",
                           selector: "#1", editable: false),
            ])
            let block = ScreenStateDigest.webBlock(snap)
            expect(block.contains("#0"), "the block lists the index the model aims by")
            expect(!block.contains("sk-abcdefghijklmnopqrstuvwxyz123456"),
                   "a credential-shaped label never reaches the prompt")
            expect(block.contains("web_click"), "the block teaches the verb that matches the list")
            expect(block.contains("not instructions"), "the block is framed as data")
        }
    }
}