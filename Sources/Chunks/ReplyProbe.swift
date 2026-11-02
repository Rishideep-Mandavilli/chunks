import AppKit
import ChunksKit
import Foundation

/// `--probe-reply` — what Chunks would do with a model's reply, said out loud, without a card in
/// front of anyone.
///
/// Three modes:
/// - **no argument** — the fixtures, and the assertions. A local model writes
///   `[ACT:DO:open_app:Chrome]`, a tool inside the act grammar, and the parser's correct answer is to
///   show it as text. That is right on his screen and invisible in a unit suite, because the suite
///   builds the tags it wants. These fixtures are the shapes it has actually been photographed
///   writing, and the check is that the audit still names them malformed.
/// - `--text "…"` / `--file <path>` — audit one reply, yours.
/// - `--local [--model …]` — ask the real local model a plan question with the production prompt and
///   audit what it answers, which is the only way to see a model's grammar drift before an audience
///   does. Exits non-zero when a plan question produces not one usable request.
@MainActor
enum ReplyProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-reply") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    // MARK: - Fixtures

    struct Fixture {
        let name: String
        let reply: String
        /// How many tags must come back malformed. Not zero by preference: these are the shapes a
        /// model writes, and a probe that reports a clean sweep for all of them has stopped measuring.
        let malformed: Int
        /// How many steps the plan holds behind a launch, or nil when it must hold none.
        let held: Int?
        /// Whether the launch is allowed to lead the plan itself — true only when every step is named.
        let leads: Bool
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "a tool inside the act grammar (Gemma, photographed 2026-11-01)",
            reply: "<SAY>Opening Chrome and typing that in now.</SAY>\n"
                + "[ACT:DO:open_app:Chrome]\n"
                + "[TYPE:368,497:area 51]\n"
                + "<NEXT_ACTIONS>\n- press enter on the search bar\n</NEXT_ACTIONS>",
            malformed: 2, held: nil, leads: false),
        Fixture(
            name: "a launch in front of a pixel aim",
            reply: "<SAY>Opening Chrome, then typing your search.</SAY>\n"
                + "[DO:open_app:Chrome]\n"
                + "[TYPE:368,497:search box|how to use sql]\n"
                + "<SUMMARY>Chrome open and the search typed</SUMMARY>",
            malformed: 0, held: 1, leads: false),
        Fixture(
            name: "a launch in front of named steps",
            reply: "<SAY>Opening Chrome and searching.</SAY>\n"
                + "[DO:open_app:Chrome]\n"
                + "[ACT:app=Chrome name=Search]",
            malformed: 0, held: nil, leads: true),
        Fixture(
            name: "a tool that changes no window",
            reply: "<SAY>Typing it in, and turning you down a little.</SAY>\n"
                + "[DO:set_volume:40]\n"
                + "[TYPE:368,497:search box|hi]",
            malformed: 0, held: nil, leads: false),
        Fixture(
            name: "a scroll that lost its direction",
            reply: "<SAY>Looking further down.</SAY>\n[SCROLL:500,500:the list]",
            malformed: 1, held: nil, leads: false),
        Fixture(
            // Both notebook tags in one reply, since 3.3 gave them a consumer. The audit has to know
            // them by name: a tag it does not recognise is a tag whose failure it silently reports as
            // ordinary prose.
            name: "a note kept and a note asked for",
            reply: "<SAY>Keeping that, and looking up the landlord.</SAY>\n"
                + "<NOTE>the landlord is Sharma, flat 4B</NOTE>\n"
                + "[NOTES:gate code]",
            malformed: 0, held: nil, leads: false),
        Fixture(
            name: "an empty notebook search is shown, not run",
            reply: "<SAY>Hmm.</SAY>\n[NOTES:]",
            malformed: 1, held: nil, leads: false),
    ]

    // MARK: - Entry

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            if CommandLine.arguments.contains("--local") { await liveTurn() }
            else if let reply = singleReply() {
                report(reply, name: "given reply")
                exit(0)
            } else {
                exit(fixturesPass() ? 0 : 1)
            }
        }
        RunLoop.main.run()
    }

    /// The reply for `--text` / `--file`, or nil when neither was given.
    private static func singleReply() -> String? {
        if let index = CommandLine.arguments.firstIndex(of: "--text"),
           index + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[index + 1]
        }
        if let index = CommandLine.arguments.firstIndex(of: "--file"),
           index + 1 < CommandLine.arguments.count,
           let text = try? String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8) {
            return text
        }
        return nil
    }

    // MARK: - Reporting

    /// Audit one reply and print every tag's verdict, then what the plan would do with it.
    static func report(_ reply: String, name: String) -> ReplyAudit {
        let audit = ReplyAudit.audit(reply)
        out("reply(\(name)): \(audit.findings.count) construct(s), "
            + "\(audit.requests.count + audit.tools.count) request(s), "
            + "\(audit.malformed.count) malformed, \(audit.swallowed.count) swallowed")
        for finding in audit.findings {
            let verdict = finding.becameARequest
                ? (finding.visibleOnCard ? "VISIBLE+RAN" : "RAN")
                : (finding.visibleOnCard ? "MALFORMED" : "SWALLOWED")
            out("  \(verbatim(finding.tag))  \(verdict)  — \(finding.reason)")
        }
        out("  " + planLine(audit))
        if audit.disagreesWithTheStreamer {
            out("  WARNING: this audit and the streamer's own unreadActTags=\(audit.unreadActTags) "
                + "disagree — one of them is wrong")
        }
        return audit
    }

    /// The one sentence that answers the question this task is about: does the plan survive its launch?
    static func planLine(_ audit: ReplyAudit) -> String {
        if ActionRequest.leadingTool(for: audit.requests, tools: audit.tools) != nil {
            return "plan: the launch leads \(audit.requests.count) named step(s) — "
                + "they resolve against the tree as it is after the window opens"
        }
        if let held = PlanAfterLaunch.decide(steps: audit.requests, tools: audit.tools) {
            return "plan: launch now, \(held.heldSteps.count) step(s) held for a fresh capture — "
                + "\"\(held.instruction)\""
        }
        return "plan: nothing held — \(audit.requests.count) step(s) run against this capture"
    }

    private static func verbatim(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "↵")
    }

    // MARK: - Fixtures pass?

    private static func fixturesPass() -> Bool {
        var failures: [String] = []
        for fixture in fixtures {
            let audit = report(fixture.reply, name: fixture.name)
            if audit.malformed.count != fixture.malformed {
                failures.append("\(fixture.name): expected \(fixture.malformed) malformed tag(s), "
                    + "got \(audit.malformed.count)")
            }
            let held = PlanAfterLaunch.decide(steps: audit.requests, tools: audit.tools)
            if let expected = fixture.held, held?.heldSteps.count != expected {
                failures.append("\(fixture.name): expected \(expected) step(s) held, "
                    + "got \(held?.heldSteps.count ?? 0)")
            }
            if fixture.held == nil, let held {
                failures.append("\(fixture.name): nothing should be held, but \(held.heldSteps.count) "
                    + "step(s) were — \(held.instruction)")
            }
            let leads = ActionRequest.leadingTool(for: audit.requests, tools: audit.tools) != nil
            if leads != fixture.leads {
                failures.append("\(fixture.name): leadingTool said \(leads), expected \(fixture.leads)")
            }
            if audit.disagreesWithTheStreamer {
                failures.append("\(fixture.name): the audit disagrees with unreadActTags="
                    + "\(audit.unreadActTags)")
            }
        }
        // A fixture set that silently measures nothing is the failure mode this repo has been bitten
        // by twice, so the count of assertions is itself asserted.
        let asserted = fixtures.reduce(0) { $0 + 3 + ($1.held != nil ? 1 : 0) }
        out("reply: \(fixtures.count) fixture(s), \(asserted) assertion(s), "
            + "\(failures.count) failure(s)")
        for failure in failures { out("  FAIL \(failure)") }
        if failures.isEmpty { out("reply: PASS") }
        return failures.isEmpty
    }

    // MARK: - The real local model

    /// One plan question, the production prompt, and the model's own reply audited.
    ///
    /// Nothing here presses or types: the reply is parsed and reported, never offered, so the probe
    /// can be run in front of the machine without changing it.
    private static func liveTurn() async {
        out("reply(local): asking the local model a plan question…")
        let requested = flag("--model") ?? "gemma 4 e2b"
        guard let modelID = await LocalBrainProbe.selectLocalBrain(requested: requested,
                                                                   report: { out("  \($0)") })
        else {
            out("reply: SKIP: no local model to ask (Ollama not answering, or the name resolves to nothing)")
            exit(3)
        }
        let image = replyImage()
        let streamer = AnswerStreamer()
        // The model's words as they arrived, kept aside from the streamer. `displayable` is the card
        // *after* the tags were consumed, and auditing that would report a clean reply for every
        // model that works — measured 2026-11-01 on the first run of this mode, where Gemma's real
        // `[DO:open_app:Chrome]` + `[TYPE:x,499:Search|…]` + `<CONTINUE>` came back through the card
        // as two sentences and zero constructs, and the probe called it a plan with nothing in it.
        var raw = ""
        do {
            _ = try await BrainGateway().analyzeImageStreaming(
                images: image.map { [(data: $0, label: "The user's whole screen")] } ?? [],
                systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                userPrompt: "open chrome and type 'how to use sql' in the search box",
                onTextChunk: { chunk in
                    raw += chunk
                    streamer.push(chunk)
                }
            )
        } catch {
            out("reply: FAIL — the local model did not answer: \(error)")
            exit(1)
        }
        streamer.finish()
        let displayable = streamer.displayable
        out("reply(\(modelID)): the model's words, verbatim:")
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            out("  │ \(line)")
        }
        let audit = ReplyAudit.audit(raw)
        out("reply(\(modelID)): \(audit.findings.count) construct(s) in the reply, "
            + "\(audit.malformed.count) malformed, "
            + "\(streamer.actionRequests.count + streamer.toolRequests.count) request(s) the live "
            + "stream produced")
        out("  " + planLine(audit))
        if displayable.speech.isEmpty && displayable.detail.isEmpty && raw.isEmpty {
            out("reply: FAIL — the model answered with nothing at all")
            exit(1)
        }
        if audit.requests.isEmpty && audit.tools.isEmpty {
            out("reply: FAIL — a plan question came back with not one request Chunks can run")
            exit(1)
        }
        out("reply: PASS — \(audit.requests.count) act(s), \(audit.tools.count) tool(s) from \(modelID)")
        exit(0)
    }

    /// A picture to aim at, from the repository — never the screen, so this probe cannot be the one
    /// thing that needs a TCC grant to run.
    private static func replyImage() -> Data? {
        let candidates = ["Nautical Pastel Chunks Interface.png", "Pastel Nautical Chunks Settings Panel.png"]
        for name in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: name)) { return data }
        }
        return nil
    }

    private static func flag(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
