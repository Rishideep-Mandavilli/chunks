import SwiftUI

/// The one material: a sheet of paper with light on its top edge and its own shadow under it.
///
/// Every raised surface in Chunks goes through this, so "physical" is a decision made once rather
/// than 40 times. Two shadows, because they do different jobs: the tight one is *contact* with the
/// ground and the wide one is *height* above it. Either alone fails — contact without lift is a
/// sticker, lift without contact is a hover state that never ends.
///
/// The pressed state throws less shadow and sits a fraction lower. That is the whole argument for
/// building this as a modifier: a button that only changes colour when you push it is a light switch
/// drawn on a screen, and the point of the language is that pushing things does something.
struct PhysicalSurface: ViewModifier {
    enum Elevation {
        /// On the ground, lifting slightly.
        case raised
        /// Pushed into the paper: no lift, tighter contact.
        case pressed
        /// Cut into the paper — a well a cursor disappears into. No shadow, an inner darkening.
        case sunken
        /// No depth at all. For rows and dividers, which are not objects.
        case flat
    }

    var fill: Color = DS.Colors.raised
    var radius: CGFloat = DS.CornerRadius.large
    var elevation: Elevation = .raised
    var edge: Color = DS.Colors.line

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill))
            .modifier(Hairline(shape: shape, edge: edge))
            .modifier(LightEdge(shape: shape, radius: radius, visible: elevation != .sunken))
            .modifier(Throw(shape: shape, elevation: elevation))
    }

    /// The border, drawn inside the shape so a 1 pt line never costs 1 pt of layout.
    private struct Hairline: ViewModifier {
        var shape: RoundedRectangle
        var edge: Color

        func body(content: Content) -> some View {
            content.overlay(shape.strokeBorder(edge, lineWidth: 1))
        }
    }

    /// A light line along the top inside edge: the catch of a bevel.
    private struct LightEdge: ViewModifier {
        var shape: RoundedRectangle
        var radius: CGFloat
        var visible: Bool

        func body(content: Content) -> some View {
            // `alignment: .top` is the whole modifier. Without it the 1 pt band lands across the
            // middle of the object, and a button whose bevel runs through its own label reads as
            // struck out — which is what the first render of the ink Allow button showed.
            content.overlay(alignment: .top) {
                LinearGradient(colors: [DS.Shadow.edgeHighlight, .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 1.5)
                    .clipShape(shape)
                    .padding(.horizontal, max(0, radius - 4))
                    .allowsHitTesting(false)
                    .opacity(visible ? 1 : 0)
            }
        }
    }

    private struct Throw: ViewModifier {
        var shape: RoundedRectangle
        var elevation: Elevation

        func body(content: Content) -> some View {
            switch elevation {
            case .flat:
                content
            case .sunken:
                // An inner darkening rather than an outer shadow: the well is below the surface, so
                // nothing it throws can land on it.
                content.overlay(shape.fill(DS.Colors.ink.opacity(0.05))
                    .blur(radius: 1.5)
                    .padding(1)
                    .mask(shape)
                    .allowsHitTesting(false))
            case .raised:
                content
                    .shadow(color: DS.Shadow.contactColor, radius: DS.Shadow.contactRadius,
                            x: 0, y: DS.Shadow.contactY)
                    .shadow(color: DS.Shadow.liftColor, radius: DS.Shadow.liftRadius,
                            x: 0, y: DS.Shadow.liftY)
            case .pressed:
                content
                    .shadow(color: DS.Shadow.contactColor, radius: DS.Shadow.contactRadius,
                            x: 0, y: 0)
                    .shadow(color: DS.Shadow.pressedLiftColor,
                            radius: DS.Shadow.pressedLiftRadius, x: 0, y: DS.Shadow.pressedLiftY)
            }
        }
    }
}

extension View {
    /// Lay this view on the paper, or push it into it.
    func physical(_ fill: Color = DS.Colors.raised,
                  radius: CGFloat = DS.CornerRadius.large,
                  elevation: PhysicalSurface.Elevation = .raised,
                  edge: Color = DS.Colors.line) -> some View {
        modifier(PhysicalSurface(fill: fill, radius: radius, elevation: elevation, edge: edge))
    }
}
