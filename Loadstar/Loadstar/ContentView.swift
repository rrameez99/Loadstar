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

#Preview {
    ContentView()
        .modelContainer(for: [Exercise.self, WorkoutSession.self, SetEntry.self, DailyMetrics.self],
                        inMemory: true)
}
