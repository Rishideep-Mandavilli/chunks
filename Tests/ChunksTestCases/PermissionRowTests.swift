import ChunksKit
import ChunksTestHarness

/// Tests for the permissions list.
///
/// The panel is the first screen of the app and the only one a user cannot work around: until the
/// grants are in, nothing else responds. The five rows had drifted into five dialects of the same
/// sentence, which is the kind of thing only an assertion catches — and the one that matters most
/// here is that a Restart button appears only where restarting is what actually applies the grant.
public enum PermissionRowTests {

    private static func state(mic: Bool = false, ax: Bool = false, input: Bool = false,
                              screen: Bool = false, content: Bool = false) -> PermissionState {
        PermissionState(microphone: mic, accessibility: ax, inputMonitoring: input,
                        screenRecording: screen, screenContent: content)
    }

    public static func register() {
        TestRunner.currentSuite = "Permission rows"

        test("all five rows speak one vocabulary") {
            let rows = PermissionState.rows(for: state())
            for row in rows {
                expect(row.stateWord == "Granted" || row.stateWord == "Needed",
                       "\(row.title) said \"\(row.stateWord)\" — the list had five dialects once")
                expect(!row.purpose.isEmpty, "\(row.title) had no reason attached to it")
                expect(!row.symbol.isEmpty, "\(row.title) had no mark")
            }
        }

        test("a granted row offers nothing to press") {
            let rows = PermissionState.rows(for: state(mic: true, ax: true, input: true,
                                                       screen: true, content: true))
            expect(rows.allSatisfy { $0.actions.isEmpty },
                   "a ticked permission still had a button on it")
        }

        test("restart is offered only where the grant lands on the next launch") {
            let byKind = Dictionary(uniqueKeysWithValues: PermissionState.rows(for: state())
                .map { ($0.kind, $0.actions) })
            expect(byKind[.screenRecording]?.contains(.restart) == true,
                   "Screen Recording is applied on relaunch and the row said nothing about it")
            expect(byKind[.inputMonitoring]?.contains(.restart) == true,
                   "Input Monitoring is applied on relaunch too")
            expect(byKind[.microphone]?.contains(.restart) != true,
                   "Microphone takes effect immediately; a Restart there teaches dead buttons")
            expect(byKind[.accessibility]?.contains(.restart) != true,
                   "Accessibility applies without a relaunch")
        }

        test("accessibility is the row that can need the drag") {
            // An ad-hoc-signed build does not always appear in the list at all, which is why this
            // one row has a second door.
            let byKind = Dictionary(uniqueKeysWithValues: PermissionState.rows(for: state())
                .map { ($0.kind, $0.actions) })
            expect(byKind[.accessibility]?.contains(.findApp) == true)
            expect(byKind[.screenRecording]?.contains(.findApp) != true,
                   "Find App on the wrong row sends the user to Finder for nothing")
        }

        test("screen content appears only once its parent is granted") {
            let without = PermissionState.rows(for: state(screen: false))
            expect(!without.contains(where: { $0.kind == .screenContent }),
                   "macOS will not offer Screen Content before Screen Recording, so the row is a "
                   + "question the user cannot answer")
            let withParent = PermissionState.rows(for: state(screen: true))
            expect(withParent.contains(where: { $0.kind == .screenContent }))
        }

        test("the order is fix-this-first") {
            let titles = PermissionState.rows(for: state()).map(\.title)
            expectEqual(titles, ["Microphone", "Accessibility", "Input Monitoring",
                                 "Screen Recording"],
                        "the list order is the order a first run works through it")
        }

        test("allGranted is the gate the app already uses, not a new one") {
            // `CompanionManager.allPermissionsGranted` requires all five, Screen Content included,
            // and the panel's whole layout branches on it. Carrying that over unchanged is the
            // point: a permissions refactor that quietly loosens the readiness gate would show the
            // finished panel while the app still could not see the screen.
            expect(!PermissionState.allGranted(for: state()),
                   "an empty panel reported itself ready")
            expect(!PermissionState.allGranted(for: state(mic: true, ax: true, input: true,
                                                          screen: true, content: false)),
                   "Screen Content is part of the shipped gate; do not move it here")
            expect(PermissionState.allGranted(for: state(mic: true, ax: true, input: true,
                                                         screen: true, content: true)),
                   "all five granted and still not ready")
        }

        test("a purpose fits on the row beside it") {
            // 320 pt wide with a mark, a title and a state word on the same line: a purpose that
            // wraps to three lines turns the whole section into a wall.
            for row in PermissionState.rows(for: state()) {
                expect(row.purpose.count <= 48,
                       "\(row.title) explains itself in \(row.purpose.count) characters")
                expect(row.title.count <= 18)
            }
        }
    }
}
