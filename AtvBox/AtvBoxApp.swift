import SwiftUI

@main
struct AtvBoxApp: App {
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environmentObject(store)
        }
    }
}
