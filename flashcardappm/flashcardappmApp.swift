import SwiftUI

@main
struct flashcardappmApp: App {
    @StateObject private var store = DeckStore()

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environmentObject(store)
        }
    }
}
