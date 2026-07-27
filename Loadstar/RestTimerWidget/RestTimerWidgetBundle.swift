//
//  RestTimerWidgetBundle.swift
//  RestTimerWidget
//
//  Entry point for the widget extension. A Home Screen widget would be added to
//  this bundle alongside the Live Activity once App Groups are set up.
//

import WidgetKit
import SwiftUI

@main
struct RestTimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        RestTimerWidgetLiveActivity()
    }
}
