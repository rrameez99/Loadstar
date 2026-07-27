//
//  RestTimerActivity.swift
//  Loadstar
//
//  Live Activity definition for the rest timer — the Dynamic Island pill and the
//  Lock Screen card.
//
//  This type is shared between the app (which starts and ends the activity) and
//  the widget extension (which renders it), so it must be a member of BOTH
//  targets. In Xcode: select this file, open the File Inspector, and tick both
//  under Target Membership.
//
//  Note there is no ticking here and no periodic updates. The activity carries an
//  end *date*, and `Text(timerInterval:)` counts down against it on its own,
//  rendered by the system. That's why the countdown stays correct even though the
//  app is suspended — the same reason RestTimer stores an end date rather than a
//  counter.
//

import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct RestTimerAttributes: ActivityAttributes {
    /// Changes over the life of the activity — extended by "+30s".
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var exerciseName: String?
        var totalDuration: TimeInterval
    }

    /// Fixed for the activity's lifetime.
    var startedAt: Date
}
#endif
