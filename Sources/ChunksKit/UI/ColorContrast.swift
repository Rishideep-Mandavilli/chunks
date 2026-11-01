import Foundation

/// The maths behind "can he read this".
///
/// Every palette in this project has been re-derived at least once, and the bug class that keeps
/// recurring is a grey that measured fine on one ground and failed on another — the notch's tertiary
/// text sat at 4.0:1 on pure black and nobody noticed until it was photographed. A reskin to a light
/// ground inverts every one of those judgements, so the pairs are asserted here instead: the hexes
/// live in `DS`, and this is the test that says whether they are legible.
///
/// WCAG 2.1 relative luminance and contrast ratio, computed from sRGB components. Pure, so it runs
/// anywhere and so a colour change fails a test rather than a user's eyes.
public enum ColorContrast {

    /// The floor for body text — anything he reads for more than a glance.
    public static let bodyMinimum = 4.5
    /// The floor for large text (18 pt regular, or 14 pt bold), which the eye resolves at lower
    /// contrast by the same standard's reasoning.
    public static let largeMinimum = 3.0
    /// The floor for a non-text object whose state he has to read: a dot, a bar, a border that means
    /// something.
    public static let graphicMinimum = 3.0

    /// Relative luminance of a `#rrggbb` string, per WCAG.
    public static func luminance(hex: String) -> Double {
        let rgb = components(of: hex)
        let channel: (Double) -> Double = { value in
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
    }

    /// 1...21, the way the standard defines it: the lighter of the two over the darker.
    public static func ratio(foreground: String, background: String) -> Double {
        let light = max(luminance(hex: foreground), luminance(hex: background))
        let dark = min(luminance(hex: foreground), luminance(hex: background))
        return (light + 0.05) / (dark + 0.05)
    }

    /// Whether one hex is usable as text over another.
    public static func legible(foreground: String, background: String,
                               large: Bool = false) -> Bool {
        ratio(foreground: foreground, background: background)
            >= (large ? largeMinimum : bodyMinimum)
    }

    /// The failing pairs, as sentences. A test that says "3 colours are wrong" gets ignored; one that
    /// names the pair, the ratio and the floor is a fix list.
    public static func failures(_ pairs: [Pair]) -> [String] {
        pairs.compactMap { pair in
            let measured = ratio(foreground: pair.foreground, background: pair.background)
            let floor = pair.large ? largeMinimum : (pair.graphic ? graphicMinimum : bodyMinimum)
            guard measured < floor else { return nil }
            return "\(pair.name): \(String(format: "%.2f", measured)):1 on \(pair.background), "
                + "needs \(floor)"
        }
    }

    public struct Pair {
        public var name: String
        public var foreground: String
        public var background: String
        public var large: Bool
        public var graphic: Bool

        public init(_ name: String, _ foreground: String, on background: String,
                    large: Bool = false, graphic: Bool = false) {
            self.name = name
            self.foreground = foreground
            self.background = background
            self.large = large
            self.graphic = graphic
        }
    }

    private struct RGB { var red: Double, green: Double, blue: Double }

    private static func components(of hex: String) -> RGB {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        // Three-digit shorthand is how a designer writes a colour in a comment; a malformed string
        // reads as black rather than crashing a test run.
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return RGB(red: 0, green: 0, blue: 0) }
        return RGB(red: Double((value >> 16) & 0xFF) / 255,
                   green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }
}
