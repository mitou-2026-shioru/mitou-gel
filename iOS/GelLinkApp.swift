import SwiftUI

@main
struct GelLinkApp: App {
    @StateObject private var lab = LabModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LabView(lab: lab)
                .tint(GelPalette.ink)
                .preferredColorScheme(.light)
                .task { await lab.run() }
                .onChange(of: scenePhase) { _, phase in
                    Task { await lab.setActive(phase == .active) }
                }
        }
    }
}
