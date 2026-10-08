import AppKit
import ChunksKit
import SwiftUI

/// The notch HUD's content: a black shape that grows out of the cutout and hangs below it.
///
/// The section order, spacings and fonts here are the same values `AnswerPanelLayout.measure`
/// adds up, because that function decides how tall the window is and this view decides what
/// is inside it. They are only correct while they agree, so the constants come from
/// `AnswerPanelLayout` rather than being typed again.
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

    private struct Chip: Identifiable {
        let id: Int
        let label: String
        let isAction: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // The cutout zone. Whatever is drawn here is behind the physical notch, so it is
            // left empty and the panel's black background fills it.
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
        .frame(width: model.cardWidth, alignment: .top)
        .background(Color.black)
        .clipShape(NotchHaloShape(radius: 14))
    }

    // MARK: - Compact

    private var pill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(model.statusLine.isEmpty ? "…" : model.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
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

    private var statusColor: Color {
        switch model.phase {
        case .listening: return DS.Colors.accent
        case .failed: return Color(hex: "#E5484D")
        default: return DS.Colors.textTertiary
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headlineText)
                .font(Font(AnswerPanelLayout.statusFont))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .frame(height: AnswerPanelLayout.statusRowHeight, alignment: .leading)

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

            if !chips.isEmpty {
                Spacer().frame(height: AnswerPanelLayout.chipGap)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chips) { chip in
                        chipRow(chip)
                    }
                }
            }

            if model.confirmQuestion != nil || model.confirmResult != nil {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                confirmRow
            }

            if let note = model.memoryNote {
                Spacer().frame(height: AnswerPanelLayout.sectionGap)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AnswerPanelLayout.inset)
        .padding(.vertical, AnswerPanelLayout.inset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Point targets and suggested actions are the same widget, stacked in the order
    /// `AnswerPanelLayout.measure` counts them in: points first, then actions.
    private var chips: [Chip] {
        var out: [Chip] = model.points.enumerated().map { Chip(id: $0.offset,
                                                               label: $0.element.label,
                                                               isAction: false) }
        let offset = out.count
        out += model.actions.enumerated().map { Chip(id: offset + $0.offset,
                                                     label: $0.element,
                                                     isAction: true) }
        return out
    }

    private func chipRow(_ chip: Chip) -> some View {
        Button(action: { if chip.isAction { onSelectAction(chip.label) } }) {
            HStack(spacing: 6) {
                Image(systemName: chip.isAction ? "arrow.up.left" : "cursorarrow.click")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text(chip.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AnswerPanelLayout.chipHeight - 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Each row occupies exactly `chipHeight`, gap included, so `n * chipHeight` in the
        // measurement is the truth rather than an approximation.
        .padding(.bottom, 4)
    }

    /// The press question: one line naming the control the hit test found, then the two
    /// answers, each half the card's width.
    ///
    /// Wide targets on purpose. This is the only tap in Chunks that can change something
    /// outside the app, so "Not now" being the easy mis-tap is the failure worth designing
    /// against. The heights are `AnswerPanelLayout`'s, so the window is sized for exactly
    /// this row.
    @ViewBuilder
    private var confirmRow: some View {
        if let question = model.confirmQuestion {
            Text(question)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(height: AnswerPanelLayout.confirmQuestionHeight, alignment: .leading)

            Spacer().frame(height: AnswerPanelLayout.confirmGap)

            HStack(spacing: 8) {
                Button("Allow") { model.answerConfirm(.allowedOnce) }
                    .buttonStyle(ConfirmButtonStyle(filled: true))
                Button("Not now") { model.answerConfirm(.denied) }
                    .buttonStyle(ConfirmButtonStyle(filled: false))
            }
        } else if let result = model.confirmResult {
            Text(result)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .frame(height: AnswerPanelLayout.confirmQuestionHeight, alignment: .leading)
        }
    }

    private var headlineText: String {
        if !model.headline.isEmpty { return model.headline }
        switch model.phase {
        case .failed: return "Could not answer"
        default: return "Answer"
        }
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
private struct ConfirmButtonStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(filled ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: AnswerPanelLayout.confirmButtonRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? DS.Colors.accent : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(filled ? Color.clear : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
