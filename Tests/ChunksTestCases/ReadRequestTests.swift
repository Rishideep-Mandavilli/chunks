import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the file-read policy.
///
/// The rule under test is "nothing that holds a credential leaves this Mac", and the failure mode
/// is silent: a path that resolves into `~/.ssh` would put a private key in the same HTTPS request
/// as the user's screenshot. So the negative cases are the point, and so are the ordinary ones — a
/// policy that refuses everything is as broken as one that allows everything, and it fails quietly
/// too.
public enum ReadRequestTests {

    private static let home = "/Users/rishi"

    private static func allow(_ path: String, links: String? = nil) -> Bool {
        if case .success = ReadRequest(path: path).resolved(homeDirectory: home, symlinksResolved: links) {
            return true
        }
        return false
    }

    private static func refusal(_ path: String, links: String? = nil) -> ReadRequest.Refusal? {
        if case .failure(let why) = ReadRequest(path: path)
            .resolved(homeDirectory: home, symlinksResolved: links) { return why }
        return nil
    }

    public static func register() {
        TestRunner.currentSuite = "File read policy"

        test("the folders a developer keeps work in are readable") {
            expect(allow("~/Documents/Rishi_Projects/chunks/context.md"),
                   "the repo's own notes must be readable by voice")
            expect(allow("~/Downloads/build.log"), "a build log is the first thing worth asking about")
            expect(allow("~/Desktop/Screenshot.png.md"), "a text file on the desktop is fair game")
            expect(allow("/Users/rishi/Code/app/main.swift"), "absolute paths inside a root work too")
        }

        test("a dotfile in home is readable, because that is where the config files are") {
            expect(allow("~/.zshrc"), "why does my prompt look wrong is a real question")
            expect(allow("~/.config/starship.toml"))
        }

        test("credential stores are refused whatever the rest of the path says") {
            for path in ["~/.ssh/id_rsa", "~/.aws/credentials", "~/Library/Keychains/login.keychain-db",
                         "~/.gnupg/secring.gpg", "~/.docker/config.json"] {
                expect(refusal(path) == .secretStore,
                       "\(path) must never be sent to a model, got \(String(describing: refusal(path)))")
            }
        }

        test("a key-shaped filename is refused even in an allowed folder") {
            // The folder is fine; the file is not. This is the case a directory allow-list alone
            // misses, and the one that would have leaked a laptop's identity key.
            expect(refusal("~/Documents/id_ed25519") == .secretStore,
                   "a private key in Documents is still a private key")
            expect(refusal("~/Projects/notes/credentials") == .secretStore)
        }

        test("a symlink out of an allowed folder is judged on where it lands") {
            // `~/Documents/notes.log` pointing at the SSH key: the typed path passes every textual
            // check, so the resolved target is what decides.
            expect(refusal("~/Documents/notes.log", links: "/Users/rishi/.ssh/id_rsa") == .secretStore,
                   "following a link into .ssh must be a refusal")
            expect(allow("~/Documents/notes.log", links: "/Users/rishi/Documents/notes.log"))
        }

        test("paths outside every allowed root are refused, including the ones that climb") {
            expect(refusal("/etc/hosts") == .outsideAllowedDirectories, "system files are not in scope")
            expect(refusal("/Library/Preferences/com.apple.loginwindow.plist")
                    == .outsideAllowedDirectories)
            expect(refusal("~/Documents/../../etc/hosts") == .outsideAllowedDirectories,
                   "a `..` that escapes the root must not be laundered by the allow-list")
            expect(refusal("/Users/otherperson/secrets.txt") == .outsideAllowedDirectories,
                   "another user's home is never in scope")
        }

        test("a binary is refused before it is read, not after") {
            expect(refusal("~/Downloads/app.zip") == .binary, "a zip has no text to send")
            expect(refusal("~/Desktop/IMG_0001.heic") == .binary)
            expect(refusal("~/Documents/report.pdf") == .binary,
                   "a PDF is not text; reading it as bytes would send the model noise")
        }

        test("an empty path is refused rather than reading the home directory itself") {
            expect(refusal("   ") == .empty,
                   "a bare [READ:] must not turn into 'send me everything'")
        }

        test("the size cap is stated in the request, not discovered mid-upload") {
            expectEqual(ReadRequest.maxBytes, 24_000,
                        "the cap is the difference between a fast answer and a contended timeout")
        }

        // MARK: Parsing

        test("path and question are split on the first bar only") {
            let parsed = ReadRequest.parse("~/Downloads/build.log|why did the tests fail?")
            expect(parsed != nil, "a well-formed tag must parse")
            expectEqual(parsed?.path, "~/Downloads/build.log")
            expectEqual(parsed?.question, "why did the tests fail?")

            let secondBar = ReadRequest.parse("~/Makefile|build it|then tell me the target")
            expectEqual(secondBar?.path, "~/Makefile", "the path is only ever the first field")
            expectEqual(secondBar?.question, "build it|then tell me the target",
                        "a question containing a bar must survive intact")
        }

        test("a malformed READ fails open to the user instead of reading something") {
            expect(ReadRequest.parse("   ") == nil, "no body is not a request")
            expect(ReadRequest.parse("|what is in it") == nil,
                   "a missing path must not be guessed at")
            expect(ReadRequest.parse("a\nb") == nil,
                   "a tag the model stopped writing inside must not resolve to a file")
            let tooLong = String(repeating: "a", count: 600)
            expect(ReadRequest.parse(tooLong) == nil,
                   "a path that long is a runaway token, not a filename")
        }

        test("standardising keeps an escape visible instead of swallowing it") {
            expectEqual(ReadRequest.standardise("/a/b/../c"), "/a/c")
            expectEqual(ReadRequest.standardise("/a/../../b"), "/../b",
                        "collapsing this to /b would hide the fact that it left the root")
            expectEqual(ReadRequest.standardise("//a//b/./"), "/a/b")
        }
    }
}
