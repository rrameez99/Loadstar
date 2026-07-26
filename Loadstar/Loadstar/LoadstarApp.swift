//
//  LoadstarApp.swift
//  Loadstar
//
//  App entry point. Two jobs: build the SwiftData container, and seed the
//  exercise library the first time the app ever runs.
//

import SwiftUI
import SwiftData

@main
struct LoadstarApp: App {

    /// The SwiftData container — roughly "the database connection." Built once at
    /// launch and handed to the view tree, where `@Query` and
    /// `@Environment(\.modelContext)` pick it up automatically.
    let container: ModelContainer

    init() {
        do {
            // Every @Model type has to be declared here. Forgetting one is the most
            // common SwiftData mistake: the app compiles fine and then crashes at
            // runtime the first time you touch the missing type.
            let schema = Schema([
                Exercise.self,
                WorkoutSession.self,
                SetEntry.self,
                DailyMetrics.self,
            ])

            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )

            container = try ModelContainer(for: schema, configurations: [configuration])

            Self.seedExerciseLibraryIfNeeded(context: container.mainContext)

        } catch {
            // If the container can't be built the app has no data layer at all, so
            // there's nothing sensible to fall back to. Crashing loudly here beats
            // limping along in a broken state.
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    /// Populates the starter exercise library on first launch only.
    ///
    /// Guarded on an empty store rather than a "hasSeeded" flag, because a flag can
    /// drift out of sync with reality — if you delete every exercise, you probably
    /// do want the library back.
    @MainActor
    private static func seedExerciseLibraryIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        for exercise in Exercise.seedLibrary() {
            context.insert(exercise)
        }

        try? context.save()
    }
}
