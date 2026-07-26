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
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No data yet", systemImage: "waveform.path.ecg")
            } description: {
                Text("Recovery and strain will appear here once HealthKit is connected.")
            }
            .navigationTitle("Today")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Exercise.self, WorkoutSession.self, SetEntry.self, DailyMetrics.self],
                        inMemory: true)
}
