import ChunksKit
import ChunksTestHarness
import Foundation

/// Tests for the words that end a conversation.
///
/// This matcher decides when the model stops seeing the last ten exchanges, so both directions are
/// user-visible bugs: too eager and Chunks silently forgets the thread he is mid-way through, too
/// narrow and "new session" spends a capture and a six-second request to do nothing at all.
public enum SessionIntentTests {

    public static func register() {
        TestRunner.currentSuite = "Session intent"

        test("the plain words reset the conversation") {
            for phrase in ["new session", "start a new session", "let's start a new conversation",
                           "new chat", "clear this conversation", "start over",
                           "end this session"] {
                expect(SessionIntent.isNewSession(phrase),
                       "\"\(phrase)\" is exactly what he would say, and it did not reset")
            }
        }

        test("punctuation and case make no difference") {
            expect(SessionIntent.isNewSession("  New Session!  "),
                   "a spoken transcript arrives capitalised and punctuated")
        }

        test("a question *about* sessions is not a request to start one") {
            // The failure this guards is the expensive one: he asks what he asked yesterday, and
            // Chunks answers about a blank context.
            for phrase in ["what did I ask in the last session?",
                           "do you remember our earlier conversation",
                           "was this the session where I fixed the certificate"] {
                expect(!SessionIntent.isNewSession(phrase),
                       "\"\(phrase)\" would have thrown away the thread he was asking about")
            }
        }

        test("forget means the memory file, not the session") {
            // `prune` already answers to "forget" in this product. Two owners for one word is how a
            // stored fact gets deleted when he wanted a new conversation, or the reverse.
            for phrase in ["forget that I use vim", "forget what I told you about my brother"] {
                expect(!SessionIntent.isNewSession(phrase),
                       "\"\(phrase)\" belongs to the memory file's prune verb")
            }
        }

        test("the phrase inside a longer request does not fire") {
            // Six words is the ceiling, and this is the sentence that proves it is needed.
            expect(!SessionIntent.isNewSession(
                "open a new session of the podcast app and play the latest episode"),
                   "a request that happens to contain the words reset the conversation")
        }

        test("an empty transcript is not a reset") {
            expect(!SessionIntent.isNewSession(""))
            expect(!SessionIntent.isNewSession("   "))
        }

        // MARK: Pointing at the past

        test("a question that reaches backwards opens the archive") {
            for phrase in ["what did I ask about the certificate",
                           "the thing from yesterday, where is it",
                           "continue what we were doing",
                           "do you remember when I said I use raycast",
                           "where were we with the whatsapp plan",
                           "you said there was a setting earlier — which one"] {
                expect(SessionIntent.refersToPast(phrase),
                       "\"\(phrase)\" is asking about the past and the archive stayed shut")
            }
        }

        test("a question about this screen does not") {
            // Every turn that misses this gate saves a search and keeps an old answer out of the
            // prompt — the model describing yesterday's window while he asks about today's is the
            // failure the gate exists to prevent.
            for phrase in ["what is this error on my screen",
                           "click the send button in whatsapp",
                           "what is the second one",
                           "scroll down and tell me what appears"] {
                expect(!SessionIntent.refersToPast(phrase),
                       "\"\(phrase)\" is about the screen now, and got an archive search anyway")
            }
        }

        test("an empty question points nowhere") {
            expect(!SessionIntent.refersToPast(""))
        }
    }
}
