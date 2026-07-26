//
//  ContentView.swift
//  Loadstar
//
//  Root view — a tab bar. Today and Trends are placeholders until the HealthKit
//  and charting work lands; Log and Library are real.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "gauge.with.dots.needle.33percent") }

            LogSessionView()
                .tabItem { Label("Log", systemImage: "plus.circle.fill") }

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }

            ExerciseLibraryView()
                .tabItem { Label("Library", systemImage: "list.bullet") }
        }
    }
}

// MARK: - Today (placeholder)
//
// This becomes the recovery + strain dashboard once the HealthKit layer exists.
// Left deliberately empty rather than filled with fake numbers — placeholder data
// has a way of surviving into screenshots.

struct TodayView: View {
    @Query(sort: \DailyMetrics.date, order: .reverse) private var metrics: [DailyMetrics]
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            Group {
                if metrics.isEmpty {
                    ContentUnavailableView {
                        Label("No health data yet", systemImage: "waveform.path.ecg")
                    } description: {
                        Text("Connect Apple Health in your profile to pull in Apple Watch data.")
                    } actions: {
                        Button("Open Profile") { showingProfile = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    // Raw values for now — this is the verification step before any
                    // scoring goes on top. If these numbers look wrong, every
                    // recovery score built from them would be wrong too.
                    List(metrics) { day in
                        Section(day.date.formatted(date: .abbreviated, time: .omitted)) {
                            metricRow("HRV (SDNN)", day.hrvSDNN, "ms")
                            metricRow("Resting HR", day.restingHeartRate, "bpm")
                            metricRow("Respiratory rate", day.respiratoryRate, "br/min")
                            metricRow("Wrist temp Δ", day.wristTemperatureDelta, "°C")
                            metricRow("Sleep", day.sleepDurationMinutes.map { $0 / 60 }, "h")
                            metricRow("Deep", day.deepSleepMinutes.map { $0 / 60 }, "h")
                            metricRow("REM", day.remSleepMinutes.map { $0 / 60 }, "h")
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingProfile = true
                    } label: {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView()
            }
        }
    }

    @ViewBuilder
    private func metricRow(_ label: String, _ value: Double?, _ unit: String) -> some View {
        if let value {
            LabeledContent(label, value: String(format: "%.1f %@", value, unit))
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Exercise.self, WorkoutSession.self, SetEntry.self, DailyMetrics.self],
                        inMemory: true)
}
