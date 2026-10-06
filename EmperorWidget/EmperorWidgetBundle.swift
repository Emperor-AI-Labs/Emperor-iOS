import SwiftUI
import WidgetKit

/// The widget extension's entry point. One widget for now: what is listed today.
@main
struct EmperorWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
