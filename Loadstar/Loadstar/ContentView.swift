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
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "gauge.with.dots.needle.33percent") }

            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "figure.strengthtraining.traditional") }

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }

            ExerciseLibraryView()
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
