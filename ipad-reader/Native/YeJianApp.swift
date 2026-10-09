import SwiftUI

@main
struct YeJianApp: App {
    @StateObject private var store = ReaderStore()
    @StateObject private var chat = ChatConnectionStore()
    @StateObject private var notebooks = NotebookStore()
    @StateObject private var voice = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ReaderRootView().environmentObject(store).environmentObject(chat).environmentObject(notebooks).environmentObject(voice).tint(ReaderPalette.sage)
                .task { chat.setActive(true); voice.refresh(); ReaderTemporaryFiles.clearExpired() }
                .onChange(of: scenePhase) { chat.setActive(scenePhase == .active); if scenePhase == .background { voice.stop(); store.saveInBackground(); notebooks.saveInBackground() } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in voice.releaseIdleModels(); ReaderPDF.releaseCache(); ReaderPDFImages.releaseCache() }
        }
    }
}
