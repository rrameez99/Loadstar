//
//  RestTimerWidgetLiveActivity.swift
//  RestTimerWidget
//
//  Lock Screen card and Dynamic Island presentation for the rest timer.
//
//  Everything here is driven by `Text(timerInterval:)`, which the system renders
//  and counts down itself. The app never pushes a per-second update — it couldn't,
//  since it's suspended between sets. That's the whole reason the countdown stays
//  accurate on the Lock Screen with the app closed, and the same reason RestTimer
//  stores an end date rather than a ticking counter.
//
//  The shared `RestTimerAttributes` type lives in RestTimerActivity.swift, which
//  must belong to BOTH targets.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct RestTimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerAttributes.self) { context in
            lockScreenView(context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                        .font(.title2.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if let name = context.state.exerciseName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .font(.caption.monospacedDigit())
                    // Without a fixed width the countdown resizes as digits change
                    // and the pill visibly jitters every second.
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.cyan)
            }
        }
    }

    private func lockScreenView(_ state: RestTimerAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 5)
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Rest")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)

                if let name = state.exerciseName {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(timerInterval: Date()...state.endDate, countsDown: true)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
        }
        .padding()
    }
}
