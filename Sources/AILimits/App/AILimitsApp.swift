import SwiftUI

struct AILimitsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
