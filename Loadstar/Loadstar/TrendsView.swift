//
//  TrendsView.swift
//  Loadstar
//
//  Where the data becomes an argument rather than a list of numbers.
//
//  Three questions this screen answers, in order of how often they matter:
//    1. Is my training load going up too fast? (weekly volume + ACWR)
//    2. Am I training everything, or neglecting something? (volume by muscle)
//    3. Is my body keeping up? (HRV and resting HR against baseline)
//

import SwiftUI
import SwiftData
import Charts

struct TrendsView: View {
    @Query private var allSets: [SetEntry]
    @Query(sort: \DailyMetrics.date) private var metrics: [DailyMetrics]

    @State private var window: TimeWindow = .ninetyDays

    enum TimeWindow: String, CaseIterable, Identifiable {
        case thirtyDays = "30d"
        case ninetyDays = "90d"
        case all = "All"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .thirtyDays: return 30
            case .ninetyDays: return 90
            case .all:        return nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Picker("Window", selection: $window) {
                        ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    weeklyVolumeSection
                    muscleBalanceSection
                    hrvSection
                    restingHeartRateSection
                }
                .padding()
            }
            .navigationTitle("Trends")
        }
    }

    // MARK: - Weekly volume

    private var weeklyVolumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly volume")
                .font(.headline)

            if weeklyVolume.isEmpty {
                emptyNote("Log some sets to see volume over time.")
            } else {
                Chart(weeklyVolume, id: \.weekStart) { week in
                    BarMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Volume", week.volume)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .frame(height: 180)
                .chartYAxisLabel("kg")

                Text("Total mechanical work per week — weight × reps, summed across every working set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct WeekVolume {
        let weekStart: Date
        let volume: Double
    }

    private var weeklyVolume: [WeekVolume] {
        let calendar = Calendar.current
        let sets = filteredSets

        let grouped = Dictionary(grouping: sets) { entry -> Date in
            calendar.dateInterval(of: .weekOfYear, for: entry.timestamp)?.start
                ?? calendar.startOfDay(for: entry.timestamp)
        }

        return grouped
            .map { WeekVolume(weekStart: $0.key, volume: $0.value.reduce(0) { $0 + $1.volumeLoad }) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: - Muscle balance

    private var muscleBalanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume by muscle group")
                .font(.headline)

            if muscleVolume.isEmpty {
                emptyNote("No logged sets in this window.")
            } else {
                Chart(muscleVolume, id: \.muscle) { item in
                    BarMark(
                        x: .value("Volume", item.volume),
                        y: .value("Muscle", item.muscle.displayName)
                    )
                    .foregroundStyle(by: .value("Region", item.muscle.isUpperBody ? "Upper" : "Lower"))
                }
                .frame(height: CGFloat(muscleVolume.count) * 26 + 40)
                .chartXAxisLabel("kg")

                Text("Secondary muscles count at half credit. Because movements rotate between sessions, this is the honest answer to \"am I training my back enough\" — a single exercise's chart isn't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct MuscleVolume {
        let muscle: MuscleGroup
        let volume: Double
    }

    private var muscleVolume: [MuscleVolume] {
        var totals: [MuscleGroup: Double] = [:]

        for entry in filteredSets {
            guard let exercise = entry.exercise else { continue }
            totals[exercise.primaryMuscle, default: 0] += entry.volumeLoad
            for muscle in exercise.secondaryMuscles where muscle != exercise.primaryMuscle {
                totals[muscle, default: 0] += entry.volumeLoad * 0.5
            }
        }

        return totals
            .map { MuscleVolume(muscle: $0.key, volume: $0.value) }
            .sorted { $0.volume > $1.volume }
    }

    // MARK: - HRV

    private var hrvSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate variability")
                .font(.headline)

            let series = filteredMetrics.compactMap { day -> (Date, Double)? in
                guard let value = day.hrvSDNN else { return nil }
                return (day.date, value)
            }

            if series.isEmpty {
                emptyNote("No HRV data in this window.")
            } else {
                let mean = series.map(\.1).reduce(0, +) / Double(series.count)

                Chart {
                    // The baseline is the whole point: a raw HRV number means
                    // nothing in isolation, only relative to your own normal.
                    RuleMark(y: .value("Baseline", mean))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("baseline \(Int(mean)) ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                    ForEach(series, id: \.0) { point in
                        LineMark(
                            x: .value("Date", point.0),
                            y: .value("HRV", point.1)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 180)
                .chartYAxisLabel("ms")

                Text("Higher is generally better recovered. Apple records SDNN, not the rMSSD used in most sports-science literature, so the absolute number isn't comparable to published figures — only to your own history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Resting heart rate

    private var restingHeartRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resting heart rate")
                .font(.headline)

            let series = filteredMetrics.compactMap { day -> (Date, Double)? in
                guard let value = day.restingHeartRate else { return nil }
                return (day.date, value)
            }

            if series.isEmpty {
                emptyNote("No resting heart rate data in this window.")
            } else {
                Chart(series, id: \.0) { point in
                    LineMark(
                        x: .value("Date", point.0),
                        y: .value("RHR", point.1)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.pink)
                }
                .frame(height: 160)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("bpm")

                Text("A sustained rise of several beats above your normal often shows up a day or two before you feel run down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var cutoff: Date? {
        guard let days = window.days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }

    private var filteredSets: [SetEntry] {
        let working = allSets.filter { !$0.isWarmup }
        guard let cutoff else { return working }
        return working.filter { $0.timestamp >= cutoff }
    }

    private var filteredMetrics: [DailyMetrics] {
        guard let cutoff else { return metrics }
        return metrics.filter { $0.date >= cutoff }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }
}
