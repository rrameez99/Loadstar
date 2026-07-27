//
//  RestTimer.swift
//  Loadstar
//
//  Rest countdown between sets.
//
//  Two design decisions here are entirely about the Apple Watch coming later:
//
//  1. State is an *end date*, not a ticking counter. A counter decremented by a
//     Timer stops when the app is suspended and drifts when it resumes. An end
//     date is correct whenever you look at it, on either device, with no
//     reconciliation — the watch and the phone independently derive the same
//     remaining time from the same stored instant.
//
//  2. Nothing here touches SwiftUI. It's an @Observable object any view can read,
//     so the watch app can drive and display the same timer without a rewrite.
//
//  The notification is what actually delivers the nudge — you put the phone down
//  between sets, so an in-app countdown alone would be useless.
//

import Foundation
import Observation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit)
import ActivityKit
#endif

@Observable
final class RestTimer {

    static let shared = RestTimer()

    /// When the current rest period ends. Nil means no timer running.
    private(set) var endDate: Date?

    /// Total length of the running period, kept for progress-ring maths.
    private(set) var totalDuration: TimeInterval = 0

    /// What we're resting between, for display.
    private(set) var exerciseName: String?

    private static let notificationID = "loadstar.rest.finished"

    private init() {}

    var isRunning: Bool {
        guard let endDate else { return false }
        return endDate > Date()
    }

    /// Seconds left, floored at zero. Computed on read, never stored.
    var remaining: TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSinceNow)
    }

    /// 0–1 elapsed fraction, for a progress ring.
    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return ((totalDuration - remaining) / totalDuration).clamped(to: 0...1)
    }

    var remainingText: String {
        let seconds = Int(remaining.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Control

    func start(seconds: TimeInterval, exerciseName: String? = nil) {
        guard seconds > 0 else { return }
        self.totalDuration = seconds
        self.endDate = Date().addingTimeInterval(seconds)
        self.exerciseName = exerciseName
        scheduleNotification(in: seconds, exerciseName: exerciseName)
        startOrUpdateActivity()
    }

    func stop() {
        endDate = nil
        totalDuration = 0
        exerciseName = nil
        cancelNotification()
        endActivity()
    }

    /// Extends or trims the running timer — the "+30s" button, since the set you
    /// just did was harder than the one the default was written for.
    func adjust(by seconds: TimeInterval) {
        guard let endDate else { return }
        let newEnd = endDate.addingTimeInterval(seconds)

        guard newEnd > Date() else {
            stop()
            return
        }

        self.endDate = newEnd
        self.totalDuration = max(totalDuration + seconds, 1)
        scheduleNotification(in: newEnd.timeIntervalSinceNow, exerciseName: exerciseName)
        startOrUpdateActivity()
    }

    // MARK: Live Activity

    #if canImport(ActivityKit)
    private var activity: Activity<RestTimerAttributes>?

    private func startOrUpdateActivity() {
        guard let endDate else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = RestTimerAttributes.ContentState(
            endDate: endDate,
            exerciseName: exerciseName,
            totalDuration: totalDuration
        )

        if let activity {
            // Updating an existing activity rather than starting a second one —
            // "+30s" should move the pill already on screen, not stack a new one.
            Task {
                await activity.update(
                    ActivityContent(state: state, staleDate: endDate.addingTimeInterval(60))
                )
            }
            return
        }

        do {
            activity = try Activity.request(
                attributes: RestTimerAttributes(startedAt: Date()),
                content: ActivityContent(state: state, staleDate: endDate.addingTimeInterval(60)),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled per-app in Settings, and there's a
            // system limit on concurrent activities. Neither is worth interrupting
            // a workout over — the in-app bar and the notification still work.
            activity = nil
        }
    }

    private func endActivity() {
        guard let activity else { return }
        let finished = activity
        self.activity = nil
        Task {
            await finished.end(nil, dismissalPolicy: .immediate)
        }
    }
    #else
    private func startOrUpdateActivity() {}
    private func endActivity() {}
    #endif

    // MARK: Notifications

    /// Asked for once, the first time a timer is started, rather than at launch —
    /// a permission prompt makes far more sense when the feature it's for is
    /// visibly happening.
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func scheduleNotification(in seconds: TimeInterval, exerciseName: String?) {
        cancelNotification()
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = exerciseName.map { "Next set of \($0)." } ?? "Time for your next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: Haptics

    /// Fires when the timer completes while the app is open — a notification
    /// banner isn't shown to a foreground app, so without this the timer would
    /// finish silently in exactly the case where you're watching it.
    func playCompletionFeedback() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
