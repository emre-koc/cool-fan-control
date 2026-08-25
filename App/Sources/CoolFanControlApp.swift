import SwiftUI
import FanControlCore

@main
struct CoolFanControlApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Cool Fan Control — skeleton (Milestones 0/1, Core \(FanControlCoreVersion.string))")
                .padding(40)
        }
    }
}
