//
//  RestTimerBar.swift
//  Loadstar
//
//  The floating rest countdown.
//
//  Uses TimelineView rather than a Timer object: SwiftUI drives the redraws on a
//  schedule it controls, pausing them automatically when the view is off screen.
//  A Timer would keep firing into a view nobody is looking at, and would need
//  manual invalidation on every dismissal path.
//

import SwiftUI

struct RestTimerBar: View {
    @State private var timer = RestTimer.shared
    @State private var hasPlayedCompletion = false

    var body: some View {
        // The conditional wraps the TimelineView rather than sitting inside it.
        // Inside, SwiftUI re-evaluates the branch every second and the insertion
        // transition re-fires, which is what made the bar visibly stutter.
        Group {
            if timer.endDate != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    content
                }
                .onChange(of: timer.remaining <= 0) { _, finished in
                    guard finished, !hasPlayedCompletion else { return }
                    hasPlayedCompletion = true
                    timer.playCompletionFeedback()
                }
                .onAppear { hasPlayedCompletion = false }
            }
        }
        .animation(.snappy(duration: 0.25), value: timer.endDate)
    }

    private var content: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(timer.remaining > 0 ? timer.remainingText : "Rest complete")
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())

                if let name = timer.exerciseName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                timer.adjust(by: 30)
            } label: {
                Text("+30s")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                timer.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .padding(8)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var tint: Color {
        timer.remaining > 0 ? .cyan : .green
    }
}

// MARK: - PR celebration

/// Shown inline after logging a set that beat a lifetime best.
struct PersonalRecordBadge: View {
    let records: [PersonalRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(records) { record in
                HStack(spacing: 8) {
                    Image(systemName: record.kind.symbol)
                        .foregroundStyle(.yellow)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.headline)
                            .font(.subheadline.weight(.semibold))

                        // Only meaningful when there was something to beat — the
                        // first time you log a movement, everything is a record
                        // and saying "+100%" would be silly.
                        if let improvement = record.improvement, improvement > 0 {
                            Text("+\(String(format: "%.1f", improvement * 100))% on your previous best")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.yellow.opacity(0.3), lineWidth: 1)
        )
    }
}
