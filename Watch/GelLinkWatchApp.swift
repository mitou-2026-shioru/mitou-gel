import SwiftUI

@main
struct GelLinkWatchApp: App {
    @StateObject private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchSessionView(model: session)
                .tint(.mint)
        }
    }
}
