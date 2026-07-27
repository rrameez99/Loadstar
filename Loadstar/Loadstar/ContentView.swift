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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    var body: some View {
        // The rest timer inset goes on each tab's content, never on the TabView.
        // Applied to the TabView it inserts into the TabView's own bounds, which
        // is where the tab bar already sits — so the bar lands on top of it.
        // Applied to the content, the safe area already excludes the tab bar and
        // the timer settles neatly above it.
        TabView {
            TodayView()
                .withRestTimer()
                .tabItem { Label("Today", systemImage: "gauge.with.dots.needle.33percent") }

            WorkoutsView()
                .withRestTimer()
                .tabItem { Label("Workouts", systemImage: "figure.strengthtraining.traditional") }

            TrendsView()
                .withRestTimer()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }

            ExerciseLibraryView()
                .withRestTimer()
                .tabItem { Label("Library", systemImage: "list.bullet") }
        }
        // Refresh on cold launch...
        .task {
            await HealthKitService.shared.syncRecentIfNeeded(into: context)
        }
        // ...and again whenever the app returns to the foreground, which is the
        // case that actually matters: opening the app in the morning should show
        // last night's sleep without being asked.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await HealthKitService.shared.syncRecentIfNeeded(into: context) }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Exercise.self, WorkoutSession.self, SetEntry.self, DailyMetrics.self],
                        inMemory: true)
}
