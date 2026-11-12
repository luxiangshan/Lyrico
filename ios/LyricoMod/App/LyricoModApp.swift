import SwiftUI

@main
struct LyricoModApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Lyrico Mod — TagLib \(LTTagLib.tagLibVersion())")
        }
    }
}
