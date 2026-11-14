import SwiftUI
import ChunksKit

/// The notch face (3.6 / plan P10): two eyes and a mouth that change with the turn's mood.
///
/// Deliberately inert: no gestures, no `.onHover`, no timer of its own — it only redraws when the
/// mood changes, animated with the design system's settle spring. That keeps it outside the
/// NSHostingView pointer-event crash class (a face that takes clicks or hovers is the surface that
/// faults). It lives only inside the existing notch; it is never a window or a desktop pet.
struct NotchFace: View {
    let mood: NotchMood
    var size: CGFloat = 20

    private var tint: Color {
        switch mood.tintName {
        case "success": return DS.Colors.success
        case "destructive": return DS.Colors.destructive
        case "warning": return DS.Colors.warning
        case "accent": return DS.Colors.accent
        default: return DS.Colors.ink
        }
    }

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let eyeY = h * 0.38
            let eyeL = CGPoint(x: w * 0.30, y: eyeY)
            let eyeR = CGPoint(x: w * 0.70, y: eyeY)
            let r = w * 0.09
            let ink = GraphicsContext.Shading.color(tint)

            // Eyes.
            if mood.eyesClosed {
                for p in [eyeL, eyeR] {
                    var line = Path()
                    line.move(to: CGPoint(x: p.x - r, y: p.y))
                    line.addLine(to: CGPoint(x: p.x + r, y: p.y))
                    ctx.stroke(line, with: ink, lineWidth: r * 0.9)
                }
            } else {
                let lift = mood == .pondering ? -r * 0.6 : 0
                for p in [eyeL, eyeR] {
                    let c = CGPoint(x: p.x, y: p.y + lift)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: ink)
                }
            }

            // Mouth.
            var mouth = Path()
            let mY = h * 0.68
            let mW = w * 0.34
            switch mood {
            case .happy:
                mouth.addArc(center: CGPoint(x: w / 2, y: mY - r * 0.4), radius: mW / 2,
                             startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            case .sad:
                mouth.addArc(center: CGPoint(x: w / 2, y: mY + r * 0.6), radius: mW / 2,
                             startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            case .talking:
                ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - mW / 3, y: mY - r * 0.6,
                                                width: mW * 0.66, height: r * 1.6)), with: ink)
            case .attentive, .curious:
                ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - r * 0.7, y: mY - r * 0.5,
                                                width: r * 1.4, height: r * 1.4)), with: ink)
            case .patient:
                mouth.addArc(center: CGPoint(x: w / 2, y: mY - r * 0.2), radius: mW / 2.6,
                             startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            default: // calm, asleep, pondering, focused: a quiet flat line
                mouth.move(to: CGPoint(x: w / 2 - mW / 2, y: mY))
                mouth.addLine(to: CGPoint(x: w / 2 + mW / 2, y: mY))
            }
            if !mouth.isEmpty {
                ctx.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: r * 0.9, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.settle, value: mood)
        .accessibilityLabel("Chunks is \(mood.rawValue)")
    }
}