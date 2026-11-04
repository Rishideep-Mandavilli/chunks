import AppKit
import ChunksKit
import SwiftUI

/// The notch HUD's content: a bone card that grows out of the cutout and hangs below it.
///
/// The section order, spacings and fonts here are the same values `AnswerPanelLayout.measure`
/// adds up, because that function decides how tall the window is and this view decides what
/// is inside it. They are only correct while they agree, so the constants come from
/// `AnswerPanelLayout` rather than being typed again.
///
/// The card reads top-down in the order a turn actually happens: what Chunks is doing and for how
/// long, the question that started it, the answer, what it changed on the screen, then anything it
/// needs from the user. A row that is absent costs nothing in the measurement, which is why a
/// listening pill and a finished card can share one window-sizing rule.
struct NotchHUDView: View {
    @ObservedObject var model: NotchHUDModel

    /// Tapping a suggested next action starts a new turn with it as the question.
    var onSelectAction: (String) -> Void = { _ in }

    /// Wrapped text advances by the measured `lineHeight` per line, so the spacing the text
    /// view draws is that minus the font's own size. Derived, not hard-coded: the day the
    /// measurement's line height changes, a typed `5` here would silently disagree with it.
    private static func lineSpacing(lineHeight: CGFloat, font: NSFont) -> CGFloat {
        max(0, lineHeight - font.pointSize)
    }

    @State private var chipHovered: Int?

    /// Whether *this* draft has been copied.
    ///
    /// Local, and reset when a new draft arrives: the button is the only proof that the tap did
    /// something on a surface with no click sound, and a "Copied" left standing over the next
    /// turn's message would claim a clipboard nobody has written to.
    @State private var draftCopied = false

    private struct Chip: Identifiable {
        let id: Int
        let label: String
        let isAction: Bool
    }

    /// The card's silhouette: square along the display edge, rounded at the bottom, so the cutout
    /// and the sheet read as one object.
    private var halo: NotchHaloShape { NotchHaloShape(radius: DS.CornerRadius.extraLarge) }

    var body: some View {
        zone
            .frame(width: model.cardWidth, alignment: .top)
            // Bone, like every other surface now. The band behind the physical cutout stays empty,
            // so what you see at the notch itself is the hardware; the card below it is a sheet of
            // paper hanging off that hardware, and it is drawn that way — a hairline on the edges
            // you can see, none along the top where it meets the bezel.
            .background(DS.Colors.ground)
            .clipShape(halo)
            // A 2 pt stroke clipped to its own path leaves the inner half: a 1 pt line inside the
            // silhouette, which is what `strokeBorder` would do if this shape were insettable.
            .overlay(halo.stroke(DS.Colors.line, lineWidth: 2).clipShape(halo))
    }

    @ViewBuilder private var zone: some View {
        VStack(spacing: 0) {
            // The cutout zone. Whatever is drawn here is behind the physical notch, so it is
            // left empty and the panel's ground colour fills it.
            Color.clear
                .frame(height: max(0, model.notchHeight))
                .allowsHitTesting(false)

            switch model.phase {
            case .idle:
                EmptyView()
            case .listening, .thinking, .status:
                pill
            case .result, .failed:
                card
            }
        }
    }

    // MARK: - Compact

    private var pill: some View {
        HStack(spacing: 8) {
            // The meter replaces the dot while he is talking, not beside it: two live indicators in
            // a 30 pt row fight, and the dot's whole job at that moment — "the microphone is open" —
            // is the job the bars do better, because they answer it with the microphone's own level.
            if case .listening = model.phase {
                WaveformBars(heights: model.waveform, color: statusColor)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
            Text(model.statusLine.isEmpty ? "…" : model.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if model.showsElapsed {
                Text(model.elapsedText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(model.overBudget ? DS.Colors.destructiveText
                                                      : DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, AnswerPanelLayout.inset)
        .frame(height: NotchHUDModel.pillContentHeight)
        .contentShape(Rectangle())
        // The intro hint is the only pill state that has nothing to wait for, so it is the
        // only one that answers to a click: tap it and the panel opens where the key field
        // and the permission rows live.
        .onTapGesture {
            if case .status = model.phase { model.openPanel?() }
        }
    }

    /// The dot is the only part of the card that reads from across a desk, so it carries the
    /// state on its own: blue while work is in flight, amber when the card is waiting on him,
    /// red when the turn ended without an answer, green once it has landed.
    private var statusColor: Color {
        if case .failed = model.phase { return DS.Colors.destructiveText }
        switch model.stage {
        case .waitingForYou: return DS.Colors.warningText
        case .answered: return DS.Colors.success
        default: return DS.Colors.accent
        }
    }

    // MARK: - Card

    /// The card, in the order he needs to read it.
    ///
    /// Two orders, not one. A turn that is *telling* him something reads top-down in the order it
    /// happened — stage, his question, the answer, what it changed. A turn that is *asking* has one
    /// job, and the old order buried the Allow row under the answer, a four-line plan record and two
    /// chips; the moment that can change his machine was the last thing he reached. So when a
    /// question is live it comes second, in a well, and the steps that already ran fold into one line.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            stageRow

            if model.confirmQuestion != nil {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                confirmBlock
            }

            if !model.spokenQuestion.isEmpty {
                let rows = AnswerPanelLayout.questionRowCount(for: model.spokenQuestion,
                                                              width: textWidth)
                Text(model.spokenQuestion)
                    .font(Font(AnswerPanelLayout.questionFont))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    // Tail, never middle. The centre of his sentence is where the object is:
                    // "open whatsapp, search for …, and message him hi" lost the thing he asked for.
                    .truncationMode(.tail)
                    .frame(height: rows * AnswerPanelLayout.questionRowHeight, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.speech.isEmpty {
                Text(model.speech)
                    .font(Font(AnswerPanelLayout.speechFont))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(Self.lineSpacing(lineHeight: AnswerPanelLayout.speechLineHeight,
                                                  font: AnswerPanelLayout.speechFont))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.detail.isEmpty {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                Text(model.detail)
                    .font(Font(AnswerPanelLayout.detailFont))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineSpacing(Self.lineSpacing(lineHeight: AnswerPanelLayout.detailLineHeight,
                                                  font: AnswerPanelLayout.detailFont))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.visibleActLines.isEmpty || model.foldedActCount > 0 {
                Spacer().frame(height: AnswerPanelLayout.timelineGap)
                timeline
            }

            // Counted between the timeline and the chips, in the same order
            // `AnswerPanelLayout.measure` adds it — the two must agree or the button gets cut off.
            if let draft = model.draft {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                draftBlock(draft)
            }

            if !chips.isEmpty {
                Spacer().frame(height: AnswerPanelLayout.chipGap)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chips) { chip in
                        chipRow(chip)
                    }
                }
            }

            if let note = model.memoryNote {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // One way back into a turn that died. The same object as `Allow` because it is the same
            // kind of thing — the primary action of the card the card is now waiting on — and a
            // second, weaker button for "say it again" would compete with the one that matters.
            if model.canRetry {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                Button("Ask again") { model.onRetry?() }
                    .buttonStyle(ConfirmButtonStyle(filled: true))
                    .hudLayoutProbe(.retry)
            }
        }
        .hudLayoutProbe(.cardContent)
        .padding(.horizontal, AnswerPanelLayout.inset)
        .padding(.vertical, AnswerPanelLayout.inset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The one authored moment on this surface: a step that ran arrives rather than replacing
        // the line above it, so growth is legible as work happening. 150 ms, because a plan that
        // animates slower than it runs makes the user wait on an animation of something already
        // finished.
        .animation(.easeOut(duration: 0.15), value: model.actLines.count)
        .animation(.easeOut(duration: 0.15), value: model.stage)
    }

    /// Words Chunks wrote for him to send, in a well with one button under them.
    ///
    /// A well (`sunken`), not a raised card: the message is content he takes *out* of Chunks rather
    /// than an object the card is offering, and the surface it sits in is the one thing on this card
    /// that says "this is the payload". The button says where the words go — Copy, never Send —
    /// because sending is his, and a control named for the thing the app is forbidden to do is how a
    /// tap becomes an accident. The line beside it keeps saying so after the clipboard has been
    /// written to, so the surface cannot be read as a draft that already went out.
    private func draftBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: AnswerPanelLayout.draftGap) {
            // All the words stay readable; only this viewport scrolls, never the Copy control.
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(Self.lineSpacing(lineHeight: 14, font: NSFont.systemFont(ofSize: 11)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .hudLayoutProbe(.draftText)
            }
            .frame(height: AnswerPanelLayout.draftTextHeight, alignment: .topLeading)
            .hudLayoutProbe(.draftViewport)
            .padding(.horizontal, AnswerPanelLayout.draftTextHorizontalInset)
            .padding(.vertical, AnswerPanelLayout.draftTextVerticalInset)
            .physical(DS.Colors.sunken, radius: DS.CornerRadius.small,
                      elevation: .sunken, edge: DS.Colors.line)

            HStack(spacing: 8) {
                Button(draftCopied ? "Copied" : "Copy") {
                    model.copyDraft()
                    draftCopied = true
                }
                .buttonStyle(ConfirmButtonStyle(filled: true))
                .frame(width: 96)
                .hudLayoutProbe(.draftCopy)
                .accessibilityLabel(draftCopied
                    ? "Draft copied to the clipboard"
                    : "Copy this draft to the clipboard — Chunks never sends it")

                Text(draftCopied ? "On your clipboard. Send it yourself." : "Chunks never sends it.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(height: AnswerPanelLayout.draftButtonRowHeight, alignment: .center)
        }
        .hudLayoutProbe(.draftBlock)
        // A new message is not the one he copied. Without this the button keeps reading "Copied"
        // over words nobody has put on the clipboard, which is the failure this label exists to avoid.
        .onChange(of: text) { _, _ in draftCopied = false }
    }

    /// Row 1: what Chunks is doing, and how long it has been doing it.
    ///
    /// The headline (`<DONE_TITLE>`, "Messaging Dad") rides in the same slot once there is one,
    /// because a finished answer is the stage the turn ended in. The number is right-aligned in
    /// tabular figures so it does not shift the label as it counts.
    private var stageRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(headlineText)
                .font(Font(AnswerPanelLayout.stageFont))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(model.elapsedTextOrNone)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                // Past the budget the figure is the failure, so it is drawn in the failure's colour.
                .foregroundColor(model.overBudget ? DS.Colors.destructiveText
                                                   : DS.Colors.textSecondary)
        }
        .frame(height: AnswerPanelLayout.stageRowHeight, alignment: .leading)
    }

    /// What the turn has already done to the screen, newest at the bottom.
    ///
    /// Folded rather than scrolled: the card is capped at 420 pt, and a plan long enough to
    /// overflow must not push the answer or the ask row off the bottom to show its own history.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.foldedActCount > 0 {
                // "done" when the card is asking and nothing is showing beneath the count, "earlier"
                // when it is only the top of a visible list. The number is the same fact either way;
                // the word tells him whether there is more below it to read.
                Text("+\(model.foldedActCount) "
                     + (model.visibleActLines.isEmpty ? "done" : "earlier"))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(height: AnswerPanelLayout.timelineRowHeight, alignment: .leading)
            }
            ForEach(Array(model.visibleActLines.enumerated()), id: \.offset) { _, line in
                actRow(line)
            }
        }
    }

    private func actRow(_ line: NotchHUDModel.ActLine) -> some View {
        HStack(spacing: 7) {
            // A 2 pt rule, not a bullet: the marks belong to a record of things that happened in
            // order, and a dot would read as a list of suggestions.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                // `lineStrong`, not the activity blue. These rows are a record of steps that
                // already happened; a blue mark on finished work is the palette saying two things
                // at once, and blue is reserved for work still in flight.
                .fill(DS.Colors.lineStrong)
                .frame(width: 2, height: 11)
            Text(line.text)
                .font(Font(AnswerPanelLayout.timelineFont))
                .foregroundColor(DS.Colors.textSecondary)
                // Two lines, tail-truncated, at the width the measurement charges: a refusal that
                // names the fields an app publishes carries its payload at the end of the sentence,
                // and one middle-truncated line showed neither half of it.
                .frame(width: model.cardWidth - 2 * AnswerPanelLayout.inset
                        - AnswerPanelLayout.timelineGutter, alignment: .topLeading)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let step = line.step, let of = line.of {
                Text("\(step)/\(of)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(height: AnswerPanelLayout.timelineRowCount(for: line.text,
                width: model.cardWidth - 2 * AnswerPanelLayout.inset)
                * AnswerPanelLayout.timelineRowHeight, alignment: .topLeading)
    }

    /// Point targets and suggested actions are the same widget, stacked in the order
    /// `AnswerPanelLayout.measure` counts them in: points first, then actions.
    ///
    /// None while the card is asking. The chip "press send" beside the question "Press Send in
    /// WhatsApp?" is the same act offered twice — one of them a second tap with no answer behind it —
    /// and the asking card is the one state that has no height to spare: at 405 of a 420 pt ceiling,
    /// two chip rows are the difference between an Allow button he can reach and one he cannot.
    private var chips: [Chip] {
        if model.isAsking { return [] }
        var out: [Chip] = model.points.enumerated().map { Chip(id: $0.offset,
                                                               label: $0.element.label,
                                                               isAction: false) }
        let offset = out.count
        out += model.actions.enumerated().map { Chip(id: offset + $0.offset,
                                                     label: $0.element,
                                                     isAction: true) }
        return out
    }

    /// One chip row. Only a *suggested next action* is tappable: the point chips name what the
    /// cursor already flew to, and wrapping them in a button whose action was empty made the card
    /// offer a control that answered with silence — to a click and to VoiceOver alike.
    @ViewBuilder private func chipRow(_ chip: Chip) -> some View {
        if chip.isAction {
            Button(action: { onSelectAction(chip.label) }) { chipCard(chip, pressable: true) }
                .buttonStyle(.plain)
                // Each row occupies exactly `chipHeight`, gap included, so `n * chipHeight` in the
                // measurement is the truth rather than an approximation.
                .padding(.bottom, 4)
        } else {
            chipCard(chip, pressable: false)
                .padding(.bottom, 4)
        }
    }

    private func chipCard(_ chip: Chip, pressable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: chip.isAction ? "arrow.up.left" : "cursorarrow.click")
                .font(.system(size: 10, weight: .semibold))
                // A point chip's mark is ink, not the activity blue: it names something already
                // done, and blue on this surface means work still in flight.
                .foregroundColor(chip.isAction ? DS.Colors.accentText : DS.Colors.inkMuted)
            Text(chip.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        // The capsule hugs its words. A full-width bar with nine characters in it reads as a row of
        // a table rather than an offer, and on a card capped at 420 pt the width is the only thing
        // saying what this object is. 240 pt is the longest label that still leaves the card's own
        // inset visible; past that the words truncate, as they do everywhere else on this surface.
        .frame(maxWidth: 240, alignment: .leading)
        .frame(height: AnswerPanelLayout.chipHeight - 4)
        .physical(chipHovered == chip.id && pressable ? DS.Colors.hover : DS.Colors.raised,
                  radius: DS.CornerRadius.small,
                  elevation: .raised,
                  // `raised` on the card's ground is a 1.05:1 difference, which is a shadow, not an
                  // affordance. DESIGN defines `lineControl` as the outline of something you can act
                  // on, so the tappable chips carry it and the ones that only name a point do not.
                  edge: pressable ? DS.Colors.lineControl : DS.Colors.line)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            guard pressable else { return }
            chipHovered = inside ? chip.id : (chipHovered == chip.id ? nil : chipHovered)
        }
    }

    /// The width any wrapped line on this card actually gets. One number, because the view and
    /// `AnswerPanelLayout.measure` must divide the same inset out of the same width or a row wraps in
    /// one and not the other — which is how a card gets sized short of its own content.
    private var textWidth: CGFloat {
        model.cardWidth - 2 * AnswerPanelLayout.inset
    }

    /// The press question: which step it is, one line naming the control the hit test found, then the
    /// two answers, each half the card's width.
    ///
    /// Drawn in a `sunken` well, the same material the drafted message uses to say *this is the
    /// payload* — because this payload is the decision, and the card is now waiting on it. Wide
    /// targets on purpose: this is the only tap in Chunks that can change something outside the app,
    /// so "Not now" being the easy mis-tap is the failure worth designing against, and since
    /// 2026-10-18 a permanent act (Send, Pay, Delete, Confirm) always reaches this row even with
    /// asking switched off.
    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The ordinal is a labelled line of its own, not a parenthetical in the sentence: the
            // timeline's `5/5` digits say the same kind of fact about the steps that already ran, and
            // two shapes for one fact is how he stops trusting either.
            if let step = model.confirmStep, let of = model.confirmStepTotal {
                Text("Step \(step) of \(of)")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(height: AnswerPanelLayout.confirmOrdinalHeight, alignment: .leading)
                Spacer().frame(height: AnswerPanelLayout.confirmOrdinalGap)
            }

            Text(model.confirmQuestion ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: AnswerPanelLayout.confirmQuestionHeight, alignment: .top)

            Spacer().frame(height: AnswerPanelLayout.confirmGap)

            HStack(spacing: 8) {
                Button("Allow") { model.answerConfirm(.allowedOnce) }
                    .buttonStyle(ConfirmButtonStyle(filled: true))
                    .hudLayoutProbe(.allow)
                Button("Not now") { model.answerConfirm(.denied) }
                    .buttonStyle(ConfirmButtonStyle(filled: false))
                    .hudLayoutProbe(.deny)
            }
        }
        .padding(.horizontal, AnswerPanelLayout.confirmWellInset)
        .padding(.vertical, AnswerPanelLayout.confirmWellInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .physical(DS.Colors.sunken, radius: DS.CornerRadius.medium,
                  elevation: .sunken, edge: DS.Colors.lineStrong)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.confirmStep != nil && model.confirmStepTotal != nil
            ? "Step \(model.confirmStep!) of \(model.confirmStepTotal!): "
              + "\(model.confirmQuestion ?? "")"
            : model.confirmQuestion ?? "")
    }

    private var headlineText: String {
        if case .failed = model.phase { return "Could not answer" }
        if !model.headline.isEmpty { return model.headline }
        return model.stage.label
    }
}

/// Black panel shape with the notch: square along the top edge (it meets the top of the
/// display) and rounded at the bottom, so the cutout and the card read as one object.
private struct NotchHaloShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One answer on the press question: half the card's width, so both are unmissable.
///
/// Allow is the ink object and Not now is the paper beside it — the same pair of weights the window
/// uses, so a card never has two things that both look like the primary action. Neither is blue:
/// blue is reserved for work in flight, and a blue Allow would read as a status, not a choice.
private struct ConfirmButtonStyle: ButtonStyle {
    var filled: Bool

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(filled ? DS.Colors.onInk : DS.Colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: AnswerPanelLayout.confirmButtonRowHeight)
            .physical(filled
                      ? (pressed ? DS.Colors.actionHover : DS.Colors.action)
                      : (pressed ? DS.Colors.pressed
                                 : (isHovered ? DS.Colors.hover : DS.Colors.raised)),
                      radius: DS.CornerRadius.small,
                      elevation: pressed ? .pressed : .raised,
                      edge: filled ? DS.Colors.ink : DS.Colors.line)
            .offset(y: pressed ? 1 : 0)
            .contentShape(Rectangle())
            .animation(DS.Motion.tap, value: pressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// The microphone, as nine bars of what it just heard.
///
/// The shape is the one `BlueCursorWaveformView` uses — 2 pt bars, 1.5 pt corners, the same gain and
/// the same curve — so the cursor and the notch answer a syllable with the same height. What is
/// deliberately *not* taken from it: the sine-driven idle pulse and the blue glow. A row that
/// breathes while the room is quiet is motion without a cause, and DESIGN.md bans a halo on this
/// surface.
struct WaveformBars: View {
    let heights: [CGFloat]
    let color: Color
    /// The tone a bar the room left empty is drawn in.
    ///
    /// Nine 2 pt stubs at a 1 pt pitch rendered as a dotted rule — which is the exact state this
    /// component was built to kill, because a rule looks like a microphone that never opened. A
    /// silent window therefore draws as a *rail* in the hairline tone: visibly an instrument, visibly
    /// reading nothing, and every bar that does catch a syllable leaves it in the status colour.
    var restColor: Color = DS.Colors.lineStrong

    static let maxWidth: CGFloat = 12
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 1
    /// The row's own width, so the rest rule occupies exactly the space the bars will.
    static let totalWidth: CGFloat = CGFloat(WaveformMeter.barCount)
        * (WaveformBars.barWidth + WaveformBars.gap) - WaveformBars.gap
    /// A bar at or under this fraction of full height is the room being quiet, not a voice.
    static let restLevel: CGFloat = WaveformMeter.idleHeight + 0.02
    static let restHeight: CGFloat = 3

    var body: some View {
        content
            .frame(height: Self.maxWidth, alignment: .center)
            // 60 ms, because the meter fills a window every 45 ms: shorter and the row snaps, longer and
            // it lags behind the voice it is meant to be showing.
            .animation(.linear(duration: 0.06), value: heights)
            // The bars are a restatement of what the caption and the stage line already say in words, so
            // a screen reader would be told "listening" twice by a row of rectangles.
            .accessibilityHidden(true)
    }

    /// A quiet room is one rule, not nine stubs.
    ///
    /// Nine 2 pt squares at a 1 pt pitch read as an ellipsis — the exact "did the microphone even
    /// open" doubt this meter was built to end — while a hairline across the same width reads as an
    /// instrument that is on and hearing nothing. The bars appear with the sound that makes them, and
    /// a bar that catches nothing stays in the hairline tone so the row shows the room as well as the
    /// voice.
    @ViewBuilder private var content: some View {
        if heights.allSatisfy({ $0 <= Self.restLevel }) {
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(restColor)
                .frame(width: Self.totalWidth, height: 1)
        } else {
            HStack(alignment: .center, spacing: Self.gap) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    let quiet = height <= Self.restLevel
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(quiet ? restColor : color)
                        .frame(width: Self.barWidth,
                               height: quiet ? Self.restHeight
                                   : max(Self.restHeight, Self.maxWidth * height))
                }
            }
        }
    }
}
