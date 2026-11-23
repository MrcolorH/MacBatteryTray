import WidgetKit
import SwiftUI

@main
struct BatteryControlWidgetBundle: WidgetBundle {
    var body: some Widget {
        BatteryDesktopWidget()
        if #available(macOS 26.0, *) {
            BatteryControlWidget()
        }
    }
}
