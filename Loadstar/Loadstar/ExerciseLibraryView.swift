//
//  ExerciseLibraryView.swift
//  Loadstar
//
//  Browse the exercise library, grouped by muscle. Tapping through shows what the
//  progression engine recommends next and the history behind it.
//

import SwiftUI
import SwiftData
import Charts

struct ExerciseLibraryView: View {

    /// `@Query` is SwiftData's live database read. It re-runs automatically whenever
    /// matching data changes, and the view re-renders. There is no "reload" call to
    /// make and no observer to register — this is the whole mechanism.
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var searchText = ""
    @State private var isAddingExercise = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(muscleGroupsPresent, id: \.self) { muscle in
                    Section(muscle.displayName) {
                        ForEach(exercises(for: muscle)) { exercise in
                            NavigationLink {
                                ExerciseDetailView(exercise: exercise)
                            } label: {
                                ExerciseRow(exercise: exercise)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingExercise = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingExercise) {
                ExerciseEditorView()
            }
        }
    }

    // MARK: Filtering

    private var filteredExercises: [Exercise] {
        guard !searchText.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Muscle groups that actually have exercises, in a stable anatomical order
    /// rather than alphabetical — chest/back/shoulders reads more naturally than
    /// back/biceps/calves.
    private var muscleGroupsPresent: [MuscleGroup] {
        let present = Set(filteredExercises.map(\.primaryMuscle))
        return MuscleGroup.allCases.filter { present.contains($0) }
    }

    private func exercises(for muscle: MuscleGroup) -> [Exercise] {
        filteredExercises.filter { $0.primaryMuscle == muscle }
    }
}

// MARK: - Row

struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exercise.name)
                .font(.body)

            Text("\(exercise.equipment.displayName) · \(exercise.targetRepMin)–\(exercise.targetRepMax) reps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

struct ExerciseDetailView: View {
    let exercise: Exercise

    @State private var isEditing = false

    /// Pulling every set and filtering in Swift is fine at personal-log scale —
    /// a few thousand rows at most. If this ever gets slow, the fix is a predicate
    /// on the @Query rather than a cache.
    @Query private var allSets: [SetEntry]

    var body: some View {
        List {
            Section("Next session") {
                let recommendation = ProgressionEngine.recommendation(
                    for: exercise,
                    history: allSets
                )

                VStack(alignment: .leading, spacing: 6) {
                    if recommendation.targetWeight > 0 {
                        Text("\(recommendation.setCount) × \(recommendation.targetReps) @ \(recommendation.displayWeight)")
                            .font(.title3.weight(.semibold))
                    } else {
                        Text("Pick a starting weight")
                            .font(.title3.weight(.semibold))
                    }

                    Text(recommendation.rationale.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if ProgressionEngine.isStalled(for: exercise, history: allSets) {
                    Label(
                        "No progress in the last 3 sessions — consider a deload.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            Section("Setup") {
                LabeledContent("Primary", value: exercise.primaryMuscle.displayName)
                if !exercise.secondaryMuscles.isEmpty {
                    LabeledContent(
                        "Secondary",
                        value: exercise.secondaryMuscles.map(\.displayName).joined(separator: ", ")
                    )
                }
                LabeledContent("Equipment", value: exercise.equipment.displayName)
                LabeledContent("Rep range", value: "\(exercise.targetRepMin)–\(exercise.targetRepMax)")
                LabeledContent("Increment", value: "\(formatted(exercise.weightIncrement)) \(exercise.defaultUnit.displayName)")
                LabeledContent("Loading", value: loadingSummary)
                LabeledContent(
                    "Rest",
                    value: "\(exercise.restSeconds / 60):\(String(format: "%02d", exercise.restSeconds % 60))"
                )
            }

            if !exercise.notes.isEmpty {
                Section("Notes") {
                    Text(exercise.notes)
                }
            }

            Section {
                let series = ProgressionEngine.oneRepMaxSeries(for: exercise, history: allSets)

                if series.isEmpty {
                    Text("No history yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(series, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("e1RM", point.estimate)
                        )
                        .foregroundStyle(Color.accentColor)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("e1RM", point.estimate)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    .frame(height: 180)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel("kg")
                    .padding(.vertical, 8)

                    ForEach(series.reversed(), id: \.date) { point in
                        LabeledContent(
                            point.date.formatted(date: .abbreviated, time: .omitted),
                            value: "\(formatted(point.estimate)) kg"
                        )
                        .font(.callout)
                    }
                }
            } header: {
                Text("Estimated 1RM")
            } footer: {
                // Always kilograms — e1RM is a computed comparison figure, and
                // showing it in whichever unit that day happened to use would
                // defeat the point of normalizing.
                Text("Best set of each session, converted to an estimated one-rep max and always shown in kg so sessions logged in different units stay comparable.")
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ExerciseEditorView(existing: exercise)
        }
    }

    private var loadingSummary: String {
        switch (exercise.defaultIsPerSide, exercise.defaultBarWeightKg > 0) {
        case (true, true):   return "Per side + \(formatted(exercise.defaultBarWeightKg)) kg bar"
        case (true, false):  return "Per side"
        case (false, true):  return "\(formatted(exercise.defaultBarWeightKg)) kg bar"
        case (false, false): return "Total"
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
