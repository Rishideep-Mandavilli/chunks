import ChunksTestHarness
@testable import ChunksKit

public enum SecretSweeperTests {
    public static func register() {
        TestRunner.currentSuite = "SecretSweeper"

        test("rejects a real OpenAI-style key") {
            let v = SecretSweeper.inspect("my key is sk-abc123def456ghi789jkl012")
            expect(v == .rejected(reason: "looks like a OpenAI-style key (sk-)"), "got \(v)")
            expect(!v.isAcceptable)
        }

        test("rejects Anthropic, OpenCode, GitHub, GitLab keys") {
            expect(!SecretSweeper.inspect("sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXX").isAcceptable)
            expect(!SecretSweeper.inspect("oc_sk_dc7470f6e600_-4Cwle4U").isAcceptable)
            expect(!SecretSweeper.inspect("ghp_16C7e42F292c6912E7710c838347Ae178B4a").isAcceptable)
            expect(!SecretSweeper.inspect("glpat-ABC123def456ghi789").isAcceptable)
        }

        test("rejects AWS, Google, Slack and Firebase keys") {
            expect(!SecretSweeper.inspect("AKIAIOSFODNN7EXAMPLE").isAcceptable)
            expect(!SecretSweeper.inspect("AIzaSyD-1234567890abcdefghijklmnopqrstu").isAcceptable)
            expect(!SecretSweeper.inspect("xoxb-123456789012-abcdefghijkl").isAcceptable)
            expect(!SecretSweeper.inspect("AAAAbcdefghijklmnopqrstuvwxyz012345").isAcceptable)
        }

        test("rejects JWTs, private keys and bearer headers") {
            expect(!SecretSweeper.inspect("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U").isAcceptable)
            expect(!SecretSweeper.inspect("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKC").isAcceptable)
            expect(!SecretSweeper.inspect("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345").isAcceptable)
        }

        test("rejects a long high-entropy run even with no known prefix") {
            // No provider prefix, but 44 mixed-case-alphanumeric chars is not prose.
            let v = SecretSweeper.inspect("value is 7Kq2mZ9xTb4nR8wY1cV6bN3hJ5sD0fL2gPxQ")
            expect(!v.isAcceptable, "got \(v)")
        }

        test("allows ordinary facts about work and tooling") {
            let ok = [
                "Working on a SwiftUI menu bar app",
                "Uses Raycast, not Spotlight",
                "Prefers short answers, no preamble",
                "Explain code before explaining concept",
                "Learning DaVinci Resolve colour grading",
                "Gmail address is rishideep at example dot com",
            ]
            for f in ok {
                expect(SecretSweeper.inspect(f).isAcceptable, "wrongly rejected: \(f)")
            }
        }

        test("does not reject a long hyphenated filename") {
            // 40+ chars, but all lowercase and hyphenated — looksRandom() should reject it as a secret.
            let v = SecretSweeper.inspect("file is very-long-descriptive-project-name-final-v2")
            expect(v.isAcceptable, "wrongly rejected a filename: \(v)")
        }

        // AUDIT.md D-02: the class test needed an uppercase letter, so an all-lowercase hex
        // credential walked into plaintext memory.md. The bias is toward rejection.
        test("rejects an all-lowercase hex credential") {
            let v = SecretSweeper.inspect("client secret is 4f8a2b9c1d6e3f7a0b5c8d2e9f4a6b1c")
            expect(!v.isAcceptable, "a lowercase hex secret was accepted: \(v)")
        }

        test("rejects mixed-case hex and still allows prose and long digits") {
            expect(!SecretSweeper.inspect("token 4F8a2B9c1D6e3F7a0B5c8D2e9F4a6B1c").isAcceptable,
                   "mixed-case hex is a credential too")
            expect(SecretSweeper.inspect("the order number is 1234567890123456789012345678901234567890")
                .isAcceptable, "a long run of digits with no letters is not a credential")
            expect(SecretSweeper.inspect("the deadline is september twenty twenty six")
                .isAcceptable, "ordinary words must stay acceptable")
        }

        test("warns, but does not block, when a fact is about credentials") {
            let v = SecretSweeper.inspect("keep my api key in 1Password")
            if case .warned = v { } else {
                expect(false, "expected .warned, got \(v)")
            }
            expect(v.isAcceptable, "warnings must not block the write")
        }

        test("the content sweep refuses real tokens but not a log of checksums") {
            // AUDIT.md D-03: file contents are swept with the hard patterns only, because the
            // entropy heuristic would refuse his build logs full of sha256 sums.
            expect(!SecretSweeper.inspectTokens("key sk-abcdefghijklmnopqrstuvwx").isAcceptable,
                   "a provider token in a file must not reach a model")
            let log = "sha256  " + String(repeating: "a1", count: 32) + "  build/output.ipa"
            expect(SecretSweeper.inspectTokens(log).isAcceptable,
                   "a checksum log is the headline capability, not a credential")
        }

        test("masking never leaks the middle of a secret") {
            let secret = "sk-abc123def456ghi789jkl012"
            let m = SecretSweeper.mask(secret)
            expect(!m.contains("def456ghi"), "mask leaked secret body: \(m)")
            expect(m.contains("sk-a"), "mask should keep a short recognisable prefix: \(m)")
            expect(SecretSweeper.mask("short") == "***")
        }
    }
}
