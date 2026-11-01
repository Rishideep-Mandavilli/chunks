import Foundation

/// Which of the permissions Chunks needs, and what the panel says about each.
///
/// The panel used to hold five hand-written rows, each about seventy lines, and they had already
/// drifted: two offered a Restart button and three did not, one said "Find App" where the others
/// said nothing, and the granted state was a different colour of green in two of them. A row is
/// data — a name, a mark, a state and the things you can do about it — so the data is here, where
/// the vocabulary can be tested, and the panel draws whatever this returns.
public struct PermissionRow: Equatable, Sendable, Identifiable {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case microphone
        case accessibility
        case inputMonitoring
        case screenRecording
        case screenContent
    }

    /// What the row offers when the grant is missing.
    ///
    /// `restart` is only offered where macOS actually applies the tick on the next launch —
    /// Screen Recording and Input Monitoring. A Restart button that would not help is a button that
    /// teaches the user to press things that do nothing.
    public enum Action: String, Equatable, Sendable, CaseIterable {
        case grant
        case restart
        case findApp

        /// The word on the button. One place, so the five rows cannot each invent their own.
        public var title: String {
            switch self {
            case .grant: return "Grant"
            case .restart: return "Restart"
            case .findApp: return "Find App"
            }
        }

        /// What the button does, for the tooltip. A row with two small pills and no explanation is
        /// a coin flip between "open System Settings" and "relaunch the app".
        public var help: String {
            switch self {
            case .grant: return "Ask macOS for this permission."
            case .restart: return "macOS applies this grant on the next launch."
            case .findApp: return "Shows Chunks in Finder and opens the Accessibility pane."
            }
        }
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var title: String
    /// The SF Symbol. A mark per permission is the only way the list is scannable at 320 pt wide.
    public var symbol: String
    /// One line on what the permission is for, in the same register as the others. A list of five
    /// "Grant" buttons with no reason attached is a list the user clicks through without reading.
    public var purpose: String
    public var isGranted: Bool

    public var actions: [Action] {
        if isGranted { return [] }
        switch kind {
        case .microphone, .screenContent: return [.grant]
        case .accessibility: return [.grant, .findApp]
        case .inputMonitoring, .screenRecording: return [.grant, .restart]
        }
    }

    /// The state word. Two values, used by all five rows — the old list had "Granted" in one place
    /// and a bare green dot in another.
    public var stateWord: String { isGranted ? "Granted" : "Needed" }
}

/// The five booleans the panel needs, and the order it shows them in.
public struct PermissionState: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var screenRecording: Bool
    public var screenContent: Bool

    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool,
                screenRecording: Bool, screenContent: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.screenRecording = screenRecording
        self.screenContent = screenContent
    }

    /// The rows worth showing, in the order a user fixes them: the one that makes the app work at
    /// all, then the ones that make it see, then the one that only exists once its parent is
    /// granted.
    ///
    /// Screen Content is hidden until Screen Recording is granted because macOS will not offer it
    /// before then — a row the user cannot satisfy is a row that reads as broken.
    public static func rows(for state: PermissionState) -> [PermissionRow] {
        var rows: [PermissionRow] = [
            PermissionRow(kind: .microphone, title: "Microphone", symbol: "mic",
                          purpose: "Hears you through the talk key.",
                          isGranted: state.microphone),
            PermissionRow(kind: .accessibility, title: "Accessibility", symbol: "hand.raised",
                          purpose: "Finds the control and presses it.",
                          isGranted: state.accessibility),
            PermissionRow(kind: .inputMonitoring, title: "Input Monitoring", symbol: "keyboard",
                          purpose: "Without it the keyboard chords hear nothing.",
                          isGranted: state.inputMonitoring),
            PermissionRow(kind: .screenRecording, title: "Screen Recording",
                          symbol: "rectangle.dashed.badge.record",
                          purpose: "Sees the screen you are pointing at.",
                          isGranted: state.screenRecording),
        ]
        if state.screenRecording {
            rows.append(PermissionRow(kind: .screenContent, title: "Screen Content", symbol: "eye",
                                      purpose: "Reads a window's own text, not a photo of it.",
                                      isGranted: state.screenContent))
        }
        return rows
    }

    /// Every row that can be shown is granted. Screen Content counts only when it is on screen,
    /// for the same reason the list hides it.
    public static func allGranted(for state: PermissionState) -> Bool {
        rows(for: state).allSatisfy(\.isGranted)
    }
}
