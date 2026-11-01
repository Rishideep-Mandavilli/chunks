import ChunksKit
import Foundation

/// `--probe-prompt` — print what Chunks actually puts in front of the model, in the order it goes.
///
/// "How does the memory work" is not answerable from a description, because the honest answer is a
/// list of budgets and a file on disk. This prints the real thing against the real stores: what it
/// knows about him, which conversations it knows *happened*, the last exchanges of this one, what a
/// recall question would dig up, and what is scheduled. Read-only, and it makes no request.
@MainActor
enum PromptProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-prompt") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let question = CommandLine.arguments.drop(while: { $0 != "--probe-prompt" }).dropFirst()
            .joined(separator: " ")

        let memory = MemoryStore(fileURL: MemoryStore.defaultURL())
        out("── what it knows about you — memory.md, \(memory.byteCount)/"
            + "\(MemoryStore.byteCap) bytes, \(memory.facts.count) facts"
            + (memory.isFull ? " — FULL, new facts will be refused" : ""))
        out(memory.injectedBlock().isEmpty ? "(nothing yet)" : memory.injectedBlock())

        let conversation = ConversationStore.load()
        // What the request is made of, because "the answer is slow" is a question about size as much
        // as about the provider: every thousand characters here is paid for on every turn.
        let system = CompanionManager.companionVoiceResponseSystemPrompt
            + CompanionManager.actingRules(askBeforeActing: false)
        let replay = conversation.recent()
        out("\n── the request's own weight")
        out("system prompt: \(system.count) chars (~\(system.count / 4) tokens)"
            + " · history replayed: \(replay.count) exchanges / "
            + "\(replay.reduce(0) { $0 + $1.asked.count + $1.answered.count }) chars"
            + " · memory: \(memory.injectedBlock().count) chars"
            + " · session index: \(conversation.sessionIndex().count) chars")
        // The protocol lines, printed whole. A tag the code supports and the prompt never mentions is
        // a feature that does not exist — the model cannot emit a block it has never been told about,
        // and no unit test can see it, because the tests build the tag by hand. This is the only place
        // the assembled string is read back.
        out("\n── what it is told about the reply's shape")
        let protocolLines = system.split(separator: "\n").filter { line in
            line.contains("<SAY>") || line.contains("<DRAFT>") || line.contains("[DO:")
                || line.contains("[ACT:") || line.contains("[TYPE:") || line.contains("[SCROLL:")
                || line.contains("[READ:") || line.contains("<CONTINUE>")
        }
        for line in protocolLines { out("· \(line)") }
        if protocolLines.isEmpty { out("(nothing — the prompt describes no tags at all)") }
        out("\n── every conversation it knows about — the session index")
        out(conversation.sessionIndex().isEmpty
            ? "(no conversations yet)" : conversation.sessionIndex())

        out("\n── this sitting, replayed to the model — \(conversation.recent().count) of "
            + "\(conversation.sessionTurns().count) exchanges "
            + "(session \(conversation.sessionsReversed().count), "
            + "cap \(ConversationStore.maxTurnsPerSession))")
        for turn in conversation.recent() {
            out("• \(turn.asked.prefix(60)) → \(turn.answered.prefix(60))")
        }

        out("\n── what a question about the past would recall"
            + (question.isEmpty ? " — give it one: --probe-prompt \"the certificate thing\"" : ""))
        if !question.isEmpty {
            let hits = conversation.recall(query: question)
            if hits.isEmpty { out("(nothing — the words do not appear in an older conversation)") }
            for hit in hits { out("• \(hit.asked.prefix(70)) → \(hit.answered.prefix(70))") }
        }

        let routines = RoutinesStore.load()
        out("\n── what is scheduled")
        out(routines.routines.isEmpty ? "(nothing)"
            : routines.routines.map { "• \($0.title) — \($0.cadence.phrase)" }
            .joined(separator: "\n"))
        Log.flush()
        exit(0)
    }
}
