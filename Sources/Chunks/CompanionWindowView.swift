import ChunksKit
import SwiftUI

/// The window: his conversations, the way every chat app he already uses organises them.
///
/// A flat list of threads under `Today` / `Yesterday` / the day's name, one thread read as a
/// conversation, and a composer along the bottom. What the earlier version had — the sitting, the
/// thread, the exchange — is still here, but as *information* rather than as indentation: the day
/// heading does the grouping a person actually scrolls by, and the sitting is one hairline with the
/// reason written next to it, shown only where a day contains more than one.
///
/// Small text follows the card's rule: `textSecondary`, never `textTertiary` for anything that has to
/// be read. The ground is `#f5f4f0` and 10 pt at the faintest step measures 4.5:1 against it, which
/// is the body threshold — so it is reserved for labels, not sentences.
struct CompanionWindowView: View {
    @ObservedObject var model: CompanionWindowModel
    /// Watched only for the one honest line while a turn is running. The answer itself is not
    /// mirrored here mid-stream — two surfaces streaming one reply is two places to keep in sync.
    @ObservedObject var hud: NotchHUDModel
    /// Handed in by the host so the view does not reach a pipeline it cannot be drawn without.
    var ask: (String) -> Void = { _ in }
    var forget: (UUID) -> Void = { _ in }
    var beginSession: () -> Void = {}

    @State private var draft = ""
    @State private var hoveredThreadID: UUID?
    @State private var newHovering = false
    /// True until he clicks an older thread. A new answer takes the pane only while he is still
    /// following the newest one; reading an old conversation must not yank him out of it.
    @State private var followsNewest = true
    @FocusState private var composerFocused: Bool

    private static let sidebarWidth: CGFloat = 280
    /// The measure a paragraph is readable at. A transcript stretched across a 1200 pt window is two
    /// columns of eye-travel per line, which is why every chat app pins its text to a width like
    /// this and centres it.
    private static let readingWidth: CGFloat = 680
    /// Room for the traffic lights: the window's content runs under them, so the sidebar's first row
    /// starts below them rather than beside them.
    private static let chromeHeight: CGFloat = 30

    /// The window's colour vocabulary, resolved to the dots warm-paper tokens — the same resolution
    /// the panel uses, so the two surfaces cannot drift into two papers. State colours and the ink
    /// action object stay shared with the notch card.
    private enum C {
        static var ground: Color { DS.Dots.paper }
        static var background: Color { DS.Dots.paper }
        static var raised: Color { DS.Dots.raised }
        static var surface1: Color { DS.Dots.raised }
        static var sunken: Color { DS.Dots.sunken }
        static var surface2: Color { DS.Dots.sunken }
        static var hover: Color { DS.Dots.hover }
        static var surface3: Color { DS.Dots.hover }
        static var pressed: Color { DS.Dots.pressed }
        static var surface4: Color { DS.Dots.pressed }
        static var line: Color { DS.Dots.line }
        static var borderSubtle: Color { DS.Dots.line }
        static var lineStrong: Color { DS.Dots.lineStrong }
        static var borderStrong: Color { DS.Dots.lineStrong }
        static var lineControl: Color { DS.Colors.lineControl }
        static var ink: Color { DS.Dots.ink }
        static var textPrimary: Color { DS.Dots.ink }
        static var inkMuted: Color { DS.Colors.inkMuted }
        static var textSecondary: Color { DS.Colors.inkMuted }
        static var inkFaint: Color { DS.Colors.inkFaint }
        static var textTertiary: Color { DS.Colors.inkFaint }
        static var onInk: Color { DS.Colors.onInk }
        static var action: Color { DS.Colors.action }
        static var actionHover: Color { DS.Colors.actionHover }
        static var accent: Color { DS.Colors.accent }
        static var accentText: Color { DS.Colors.accentText }
        static var accentSubtle: Color { DS.Colors.accentSubtle }
    }

    private var isTurnInFlight: Bool {
        switch hud.phase {
        case .listening, .thinking: return true
        case .idle, .result, .failed, .status: return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            DotsDashRule(vertical: true)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                detail
                DotsDashRule()
                composer
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(C.background)
        .onAppear {
            composerFocused = true
            model.select(chatID: model.latestChatID)
        }
        .onChange(of: model.totalTurns) { _ in
            guard followsNewest else { return }
            model.select(chatID: model.latestChatID)
        }
    }

    // MARK: - The list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: Self.chromeHeight)
            brandRow
            if model.threads.isEmpty {
                emptyList
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.days) { day in
                            dayLabel(day.label)
                            ForEach(day.threads) { thread in
                                if let sitting = thread.earlierSitting {
                                    sittingLine(sitting)
                                }
                                threadRow(thread)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: Self.sidebarWidth)
        // The rail is the sky field, hatched — the reference's left column. Ink and muted are the
        // only two text weights legal on sky (9.30:1 and 4.88:1); `inkFaint` measures 3.11:1 there
        // and is banned by the contrast suite, so nothing small and grey may be dropped onto it.
        // One background layer, not three. A second `.background` sits *behind* the first, so an
        // opaque sky fill added after the clouds hid them completely — which is what the previous
        // render showed. ZStack orders them: sky, clouds on its bottom edge, hatch over both.
        .background {
            ZStack(alignment: .bottomLeading) {
                DS.Dots.skyRail
                // The rail ends in a strip of deep sea, the way the mockup's left column meets the
                // water at its foot. The clouds rest on that strip's top edge.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    DS.Dots.seaDeep
                        .frame(height: 46)
                        .overlay(DS.Dots.HatchPattern())
                }
                DS.Dots.CloudBand(squash: 0.6)
                    .frame(width: 220, height: 20)
                    .padding(.bottom, 46)
                DS.Dots.HatchPattern()
            }
        }
    }

    /// The wordmark and the one action this window has: start again.
    ///
    /// "New conversation" rather than "New session", because that is what he is asking for in his own
    /// words; what it *does* — end this sitting, leave the older ones recallable — is what the help
    /// line says, because a button that silently truncates nothing needs no explanation but a button
    /// that looks like it might does.
    private var brandRow: some View {
        HStack(spacing: 8) {
            Text("Chunks")
                .font(DS.Fonts.headline)
                .foregroundStyle(C.textPrimary)
            Text("\(model.totalTurns)")
                .font(DS.Fonts.micro)
                .foregroundStyle(C.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(action: startConversation) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(.system(size: 10, weight: .semibold))
                    Text("New conversation").font(DS.Fonts.label)
                }
                .foregroundStyle(C.onInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .physical(newHovering ? C.actionHover : C.action,
                          radius: DS.CornerRadius.pill, elevation: .raised,
                          edge: C.ink)
            }
            .buttonStyle(.plain)
            .onHover { newHovering = $0 }
            .help("End this conversation. Everything asked before it stays here, and Chunks can still recall it.")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func startConversation() {
        beginSession()
        followsNewest = true
        model.select(chatID: model.latestChatID)
    }

    /// `Today`, `Yesterday`, the weekday, the date — the heading a scrolled list is navigated by.
    private func dayLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(DS.Fonts.micro)
            .foregroundStyle(C.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    /// Where one sitting ends and an older one begins, in the machine's own words.
    private func sittingLine(_ phrase: String) -> some View {
        HStack(spacing: 6) {
            rule(width: 10, height: 1)
            Text(phrase)
                .font(DS.Fonts.micro)
                .foregroundStyle(C.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func threadRow(_ thread: HistoryGrouping.Thread) -> some View {
        let isSelected = model.selectedChatID == thread.id
        return Button(action: { select(thread) }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(thread.title)
                            .font(DS.Fonts.label)
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if thread.open {
                            Circle().fill(C.accent).frame(width: 4, height: 4)
                        }
                    }
                    Text(thread.detail)
                        .font(DS.Fonts.micro)
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(thread.time)
                    .font(DS.Fonts.micro)
                    .foregroundStyle(C.textSecondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: isSelected, hovered: hoveredThreadID == thread.id))
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            // The fill alone is a 1.28:1 difference between the chosen row and the paper it sits on,
            // which is a surface, not a signal. The 2 pt rule is this app's existing "here is the
            // thing" mark — the same one the act lines use on the card — and it is a bar on the
            // leading edge, not the coloured border around the row that DESIGN bans.
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(DS.Dots.teal)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                // The rail's rows are separated by the same dashed rule as everywhere else on the
                // nautical surfaces; a solid hairline between two of them reads as a second system.
                DotsDashRule()
                    .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredThreadID = inside ? thread.id : (hoveredThreadID == thread.id ? nil : hoveredThreadID)
        }
    }

    private func select(_ thread: HistoryGrouping.Thread) {
        followsNewest = false
        model.select(chatID: thread.id)
    }

    /// Selection is a surface, not a border: the banned list here is a coloured border on a row.
    ///
    /// On the sky rail the chosen row is the sea field itself — the reference's own answer to
    /// "which one is open" — and a hovered row is a half-strength version of it, so the two states
    /// are one ramp rather than two unrelated greys.
    private func rowBackground(selected: Bool, hovered: Bool) -> Color {
        if selected { return DS.Dots.seaDeep }
        if hovered { return DS.Dots.seaDeep.opacity(0.45) }
        return .clear
    }

    /// The sidebar's own nothing-yet line, in one sentence, because the pane beside it is already
    /// carrying the invitation and two empty states saying the same thing reads as a broken app.
    private var emptyList: some View {
        Text("Nothing asked yet")
            .font(DS.Fonts.meta)
            .foregroundStyle(C.textSecondary)
            .padding(.horizontal, 12)
            // Top-aligned, not centred: a `VStack` in a tall window puts its middle in the middle of
            // the window, which is where the empty state was measured sitting.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The conversation

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: Self.chromeHeight)
            if let thread = model.selectedThread {
                header(thread)
                if isTurnInFlight { liveStrip }
                rule(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(model.turns) { turn in
                                exchange(turn).id(turn.id)
                            }
                        }
                        .padding(.vertical, 22)
                        .frame(maxWidth: Self.readingWidth)
                        .frame(maxWidth: .infinity)
                    }
                    // The newest exchange has to be the one in view while he is following the thread:
                    // the pane re-selects the thread for him, and a transcript that stays scrolled to
                    // its first question shows him the past while he is reading the present.
                    .onAppear { scrollTo(proxy, model.turns.last?.id) }
                    .onChange(of: model.turns.last?.id) { newest in
                        guard followsNewest else { return }
                        scrollTo(proxy, newest)
                    }
                    .onChange(of: model.selectedChatID) { _ in
                        scrollTo(proxy, model.turns.last?.id)
                    }
                }
            } else {
                // Centred in the pane, the way every chat app greets a first run: the composer is at
                // the bottom of the same column, so an invitation pinned to the top points away from
                // the one thing he is supposed to do.
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's on your screen?")
                        .font(DS.Fonts.headline)
                        .foregroundStyle(C.textPrimary)
                    Text("Ask below, or hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) and say it — "
                            + "every answer lands here with what Chunks did.")
                        .font(DS.Fonts.meta)
                        .foregroundStyle(C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.background)
    }

    private func header(_ thread: HistoryGrouping.Thread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(thread.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(C.textPrimary)
                    .lineLimit(1)
                if thread.open {
                    Text("ongoing")
                        .font(DS.Fonts.micro)
                        .foregroundStyle(DS.Dots.ink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        // Sand, not sky — this chip now sits on the sky band, and a sky chip on sky
                        // is the same sand-on-sand mistake the clouds made.
                        .background(DS.Dots.sand)
                        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small,
                                                    style: .continuous))
                }
                Spacer(minLength: 12)
            }
            Text(model.headline(for: thread))
                .font(DS.Fonts.micro)
                .foregroundStyle(C.textSecondary)
                .monospacedDigit()
        }
        .frame(maxWidth: Self.readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 30)
        // The mockup's detail header is cream paper, not sky, with a *large* sand cloud mass hanging
        // from its top-right corner — not a thin band along the bottom. Flipping the band vertically
        // is what turns a shoreline into a sky full of cloud.
        .background {
            ZStack(alignment: .topTrailing) {
                DS.Dots.paper
                DS.Dots.CloudBand(squash: 1.5)
                    .frame(width: 430, height: 86)
                    .scaleEffect(y: -1)
                DS.Dots.HatchPattern()
            }
        }
        .overlay(alignment: .bottom) { DotsDashRule() }
    }

    /// The stage, in words, with the seconds it has taken. No progress bar and no shimmer: the
    /// honest state is "Asking the model", and a shape that implies it is nearly done would be a
    /// lie about waiting.
    private var liveStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(C.accent).frame(width: 7, height: 7)
            Text(hud.stage.label).font(DS.Fonts.label).foregroundStyle(C.textPrimary)
            Spacer()
            Text(hud.elapsedText).font(DS.Fonts.meta)
                .foregroundStyle(C.textSecondary).monospacedDigit()
        }
        .frame(maxWidth: Self.readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(DS.Dots.sand)
        .overlay(DS.Dots.HatchPattern().allowsHitTesting(false))
    }

    /// One question and the answer it got.
    ///
    /// His words go in a well cut into the ground and Chunks' answer on paper lifted off it, because
    /// the two are different kinds of thing — one is a record of what he said to a machine, the other
    /// is the thing the machine made. Reading them as two bubbles of the same weight is what makes a
    /// transcript look like a chat log rather than an answer.
    private func exchange(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(turn.asked)
                    .font(DS.Fonts.label)
                    .foregroundStyle(C.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if turn.hasRecordedDate {
                        Text(Self.clock.string(from: turn.at))
                            .font(DS.Fonts.micro)
                            .foregroundStyle(C.textSecondary)
                            .monospacedDigit()
                    }
                    Text(turn.source.phrase)
                        .font(DS.Fonts.micro)
                        .foregroundStyle(C.inkMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            // His words sit on the sea field — a flat fill with ink on it (12.55:1), hatched like the
            // rest of the paper. The answer below stays on raised paper, so the two still read as
            // different kinds of thing.
            .physical(DS.Dots.seaDeep, radius: DS.CornerRadius.medium, elevation: .sunken,
                      edge: DS.Dots.line)
            .overlay(
                DS.Dots.HatchPattern()
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium,
                                                style: .continuous))
                    .allowsHitTesting(false)
            )

            answerCard(turn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Forget this answer") { forget(turn.id) }
        }
    }

    private func answerCard(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            rendered(turn.answered.isEmpty ? "No answer was recorded." : turn.answered)
                .font(.system(size: 13))
                .foregroundStyle(C.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !turn.acts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turn.acts.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(C.lineStrong)
                                .frame(width: 2, height: 14)
                            Text(line)
                                .font(DS.Fonts.meta)
                                .foregroundStyle(C.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .physical(C.sunken, radius: DS.CornerRadius.small, elevation: .sunken,
                          edge: C.line)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .physical(C.raised, radius: DS.CornerRadius.large, elevation: .raised)
        // A solid hairline, not a dashed one: in the mockup the answer cards and the composer are
        // drawn objects with a clean edge, and only the rail's separators and the card *containers*
        // on the panel are dashed.
        .dotsSolidBorder(radius: DS.CornerRadius.large, DS.Dots.line, width: 1)
    }

    /// Take the transcript to an exchange.
    ///
    /// Called on appear as well as on change: the pane re-selects a thread when a new answer lands,
    /// and a transcript left at its top shows the oldest question in the thread to a man who just
    /// asked the newest one.
    private func scrollTo(_ proxy: ScrollViewProxy, _ id: UUID?) {
        guard let id else { return }
        withAnimation(DS.Motion.settle) { proxy.scrollTo(id, anchor: .bottom) }
    }

    /// The stored text with its markdown *rendered* rather than shown.
    ///
    /// The model answers with `localhost:5173` and **bold** because that is how it was trained, and
    /// a transcript that prints the backticks is a debug view. SwiftUI's inline-only markdown
    /// interprets them without touching newlines; the fallback is the raw string, not a regex that
    /// could eat a word.
    private func rendered(_ text: String) -> Text {
        if let marked = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(marked)
        }
        return Text(text)
    }

    // MARK: - The composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this screen", text: $draft, prompt: Text("Ask about this screen")
                // The prompt is a token now, not the system's placeholder grey. Left to AppKit it
                // measured below the floor on a sunken well, and "is this field empty or is this
                // field disabled" is the one question a composer must not let you ask.
                .foregroundStyle(C.inkMuted))
                .textFieldStyle(.plain)
                .font(DS.Fonts.label)
                .foregroundStyle(C.textPrimary)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .physical(C.raised, radius: 999, elevation: .raised,
                          edge: C.line)
                .dotsSolidBorder(radius: 999, DS.Dots.line, width: 1)

            Button(action: send) {
                Text("Ask")
                    .font(DS.Fonts.label)
                    // Ink when there is a question, paper when there is not — and `inkFaint` on the
                    // paper, because the disabled label was white on a bone fill and simply gone.
                    .foregroundStyle(canSend ? C.onInk : C.inkMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .physical(canSend ? C.action : C.sunken,
                              radius: DS.CornerRadius.pill == .infinity
                                ? 999 : DS.CornerRadius.medium,
                              elevation: canSend ? .raised : .flat,
                              edge: canSend ? C.ink : C.lineControl)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .frame(maxWidth: Self.readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(C.background)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        // He asked a new question, so the newest thread is the one he wants to be looking at — even
        // if the answer opens a new one, which is the grouping rule's decision, not this view's.
        followsNewest = true
        ask(question)
    }

    // MARK: - Rules and time

    private func rule(width: CGFloat = 0, height: CGFloat = 0) -> some View {
        Rectangle().fill(C.borderSubtle)
            .frame(width: width > 0 ? width : nil, height: height > 0 ? height : nil)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()
}
