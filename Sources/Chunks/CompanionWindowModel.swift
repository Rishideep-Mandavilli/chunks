import AppKit
import ChunksKit
import Combine
import SwiftUI

/// The window's content, held apart from the pipeline that fills it.
///
/// The same reason `NotchHUDModel` exists: a surface that can only be built by `CompanionManager`
/// can only be *looked at* by starting the microphone, the event tap and a model call. This is the
/// data the window draws; `CompanionManager` is its only writer, and the actions are handed in by
/// whoever hosts the view, so `--render-window` can lay out a full history without a brain behind
/// it.
///
/// The grouping itself is not here — it is `HistoryGrouping`, pure and tested, because which thread
/// sits under which day heading is the design rather than the decoration.
@MainActor
final class CompanionWindowModel: ObservableObject {

    /// Days newest first, as the sidebar lists them.
    @Published private(set) var days: [HistoryGrouping.Day] = []

    /// Every thread, in the same order the sidebar shows them — so a title lookup and the newest
    /// thread are answered without walking the day groups again.
    @Published private(set) var threads: [HistoryGrouping.Thread] = []

    /// Every exchange of the selected thread, oldest first — the transcript, not one row of it.
    @Published private(set) var turns: [ConversationTurn] = []

    /// The thread the window is showing. `nil` means "follow the newest", which is the state he is
    /// in while the answer he just asked for is on its way.
    @Published private(set) var selectedChatID: UUID?

    @Published private(set) var totalTurns = 0

    private var store = ConversationStore()

    var selectedThread: HistoryGrouping.Thread? {
        threads.first { $0.id == selectedChatID }
    }

    /// The newest thread, which is what the window shows before he clicks anything — and what it
    /// returns to when he asks something, so the answer he just asked for is on screen.
    var latestChatID: UUID? { threads.first?.id }

    /// Rebuild the list from the file, keeping whatever thread he was reading.
    func reload(from conversation: ConversationStore) {
        store = conversation
        totalTurns = conversation.turns.count
        days = HistoryGrouping.days(store: conversation)
        threads = days.flatMap(\.threads)
        // Re-derive the transcript after the list changes, keeping his selection when the thread it
        // points at still exists. Without this the window would show an old chat's turns under a
        // newly-clicked one.
        select(chatID: nil)
    }

    /// The transcript of one thread. Nil follows the newest.
    func select(chatID: UUID?) {
        let target = chatID ?? (selectedChatID != nil && selectedThread != nil
                                ? selectedChatID : latestChatID)
        selectedChatID = target
        turns = target.map { store.turns(inChat: $0) } ?? []
    }

    /// The line under a thread's title: what happened in it and when.
    ///
    /// Lives on the model rather than the store because it is a second, shorter reading of the same
    /// facts — the transcript header needs the act count spelled out once, not per row.
    func headline(for thread: HistoryGrouping.Thread) -> String {
        var line = "\(thread.exchanges) exchange\(thread.exchanges == 1 ? "" : "s")"
        if thread.acts > 0 { line += " · \(thread.acts) act\(thread.acts == 1 ? "" : "s")" }
        return line
    }
}
