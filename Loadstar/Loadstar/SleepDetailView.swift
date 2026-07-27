//
//  SleepDetailView.swift
//  Loadstar
//
//  The hypnogram and stage breakdown.
//
//  Totals tell you how much deep sleep you got. The timeline tells you *when* —
//  and that's the more informative question. Deep sleep normally front-loads into
//  the first few cycles, so a night with 50 minutes of deep spread thinly across
//  the whole night looks very different from 50 minutes concentrated early, even
//  though the number is identical.
//

import SwiftUI
import SwiftData
import Charts

// MARK: - Stage colours

extension SleepStage {
    var color: Color {
        switch self {
        case .awake:       return Color(red: 0.62, green: 0.64, blue: 0.70)
        case .rem:         return Color(red: 0.45, green: 0.55, blue: 0.98)
        case .core:        return Color(red: 0.36, green: 0.78, blue: 0.92)
        case .deep:        return Color(red: 0.32, green: 0.36, blue: 0.86)
        case .unspecified: return Color.gray
        }
    }
}

// MARK: - View

struct SleepDetailView: View {
    let day: DailyMetrics
    let sleepScore: Double?

    @Query(sort: \DailyMetrics.date, order: .reverse) private var history: [DailyMetrics]
    @Environment(\.dismiss) private var dismiss

    /// Which segment the user is scrubbing over, if any.
    @State private var selectedTime: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !day.sleepSegments.isEmpty {
                        hypnogram
                    }
                    stageBreakdown
                    consistencySection
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(durationText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                if let sleepScore {
                    Text("\(Int(sleepScore))%")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }

            if let start = day.sleepStart, let end = day.sleepEnd {
                Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var durationText: String {
        guard let minutes = day.sleepDurationMinutes else { return "—" }
        return "\(Int(minutes) / 60)h \(Int(minutes) % 60)m"
    }

    // MARK: Hypnogram

    private var hypnogram: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THE NIGHT")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(day.sleepSegments) { segment in
                    // RectangleMark with an x range draws a band spanning real
                    // clock time, which is what makes the gaps and the ordering
                    // legible. A BarMark would collapse each segment to a tick.
                    RectangleMark(
                        xStart: .value("Start", segment.start),
                        xEnd: .value("End", segment.end),
                        y: .value("Stage", segment.stage.displayName)
                    )
                    .foregroundStyle(segment.stage.color)
                    .cornerRadius(3)
                }

                if let selectedTime {
                    RuleMark(x: .value("Time", selectedTime))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: orderedStageNames)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: 200)
            // Drag anywhere on the chart to read the stage at that moment.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    // `plotFrame` replaced `plotAreaFrame` and is
                                    // optional, because a chart with no data has
                                    // no plot area to resolve.
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geometry[plotFrame].origin
                                    let x = drag.location.x - origin.x
                                    selectedTime = proxy.value(atX: x, as: Date.self)
                                }
                                .onEnded { _ in selectedTime = nil }
                        )
                }
            }

            if let selectedTime, let segment = segment(at: selectedTime) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(segment.stage.color)
                        .frame(width: 8, height: 8)
                    Text(segment.stage.displayName)
                        .font(.caption.weight(.medium))
                    Text("· \(selectedTime.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("· \(Int(segment.durationMinutes)) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Drag across the chart to read any moment of the night.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Stage rows top to bottom, restricted to stages actually recorded.
    private var orderedStageNames: [String] {
        let present = Set(day.sleepSegments.map(\.stage))
        return SleepStage.allCases
            .filter { present.contains($0) }
            .sorted { $0.depthRank < $1.depthRank }
            .map(\.displayName)
    }

    private func segment(at time: Date) -> SleepStageSegment? {
        day.sleepSegments.first { $0.start <= time && time <= $0.end }
    }

    // MARK: Stage breakdown

    private var stageBreakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STAGES")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)

            ForEach(stageTotals, id: \.stage) { item in
                StageBar(
                    stage: item.stage,
                    minutes: item.minutes,
                    share: item.share
                )
            }
        }
    }

    private struct StageTotal {
        let stage: SleepStage
        let minutes: Double
        let share: Double
    }

    private var stageTotals: [StageTotal] {
        // Shares are of time *in bed* so awake is representable as a slice;
        // using time asleep as the denominator would make awake unplottable.
        let total = (day.sleepDurationMinutes ?? 0) + (day.awakeMinutes ?? 0)
        guard total > 0 else { return [] }

        let pairs: [(SleepStage, Double?)] = [
            (.awake, day.awakeMinutes),
            (.rem, day.remSleepMinutes),
            (.core, day.coreSleepMinutes),
            (.deep, day.deepSleepMinutes),
        ]

        return pairs.compactMap { stage, minutes in
            guard let minutes, minutes > 0 else { return nil }
            return StageTotal(stage: stage, minutes: minutes, share: minutes / total)
        }
    }

    // MARK: Consistency

    private var consistencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LAST 14 NIGHTS")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)

            let recent = Array(history.prefix(14).reversed())
                .compactMap { d -> (Date, Double)? in
                    guard let m = d.sleepDurationMinutes else { return nil }
                    return (d.date, m / 60)
                }

            if recent.isEmpty {
                Text("No sleep history yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    RuleMark(y: .value("Need", RecoveryEngine.sleepNeedHours))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(recent, id: \.0) { point in
                        BarMark(
                            x: .value("Night", point.0, unit: .day),
                            y: .value("Hours", point.1)
                        )
                        // Under-target nights stand out without needing a legend.
                        .foregroundStyle(point.1 >= RecoveryEngine.sleepNeedHours ? Color.cyan : Color.cyan.opacity(0.35))
                        .cornerRadius(3)
                    }
                }
                .frame(height: 150)
                .chartYAxisLabel("hours")

                if let average = averageRecentHours {
                    Text(String(format: "Averaging %.1f h against an %.0f h need.", average, RecoveryEngine.sleepNeedHours))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var averageRecentHours: Double? {
        let values = history.prefix(14).compactMap(\.sleepDurationMinutes).map { $0 / 60 }
        guard !values.isEmpty else { return nil }
        return values.mean
    }
}

// MARK: - Stage bar

struct StageBar: View {
    let stage: SleepStage
    let minutes: Double
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(stage.color)
                    .frame(width: 8, height: 8)

                Text(stage.displayName)
                    .font(.subheadline.weight(.medium))

                Text("\(Int(share * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(minutes) / 60)h \(Int(minutes) % 60)m")
                    .font(.subheadline.monospacedDigit())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))

                    // The typical range, drawn as a faint band behind the bar so
                    // a number has context. Deliberately quiet — these ranges vary
                    // enormously between people, and one night says almost nothing.
                    if let range = stage.typicalRange {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .frame(
                                width: geometry.size.width * (range.upperBound - range.lowerBound),
                                height: 10
                            )
                            .offset(x: geometry.size.width * range.lowerBound)
                    }

                    Capsule()
                        .fill(stage.color)
                        .frame(width: max(3, geometry.size.width * min(share, 1)), height: 10)
                }
                .frame(height: 10)
            }
            .frame(height: 10)
        }
    }
}
