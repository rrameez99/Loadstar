//
//  RestTimerWidgetBundle.swift
//  RestTimerWidget
//
//  Entry point for the widget extension. Home Screen widgets would be added to
//  this same bundle later.
//

import WidgetKit
import SwiftUI

@main
struct RestTimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        RestTimerLiveActivity()
    }
}
