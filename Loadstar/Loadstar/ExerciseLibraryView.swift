//
//  ExerciseLibraryView.swift
//  Loadstar
//
//  Browse the exercise library, grouped by muscle. Tapping through shows what the
//  progression engine recommends next and the history behind it.
//

import SwiftUI
import SwiftData

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
                AddExerciseView()
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
                if exercise.defaultIsPerSide {
                    LabeledContent("Loading", value: "Per side")
                }
            }

            Section("Estimated 1RM") {
                let series = ProgressionEngine.oneRepMaxSeries(for: exercise, history: allSets)
                if series.isEmpty {
                    Text("No history yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // Swift Charts goes here once the charting task lands. A plain
                    // list is enough to verify the math is producing sane numbers.
                    // Always kilograms — e1RM is a computed comparison figure, and
                    // showing it in whichever unit that day happened to use would
                    // defeat the point of normalizing.
                    ForEach(series.reversed(), id: \.date) { point in
                        LabeledContent(
                            point.date.formatted(date: .abbreviated, time: .omitted),
                            value: "\(formatted(point.estimate)) kg"
                        )
                    }
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Add exercise

struct AddExerciseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var primaryMuscle: MuscleGroup = .chest
    @State private var equipment: Equipment = .barbell
    @State private var repMin = 8
    @State private var repMax = 12

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $name)
                }

                Section("Classification") {
                    Picker("Primary muscle", selection: $primaryMuscle) {
                        ForEach(MuscleGroup.allCases) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }
                    Picker("Equipment", selection: $equipment) {
                        ForEach(Equipment.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }

                Section("Target rep range") {
                    Stepper("Minimum: \(repMin)", value: $repMin, in: 1...30)
                    Stepper("Maximum: \(repMax)", value: $repMax, in: 1...30)
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || repMin > repMax)
                }
            }
        }
    }

    private func save() {
        let exercise = Exercise(
            name: name.trimmingCharacters(in: .whitespaces),
            primaryMuscle: primaryMuscle,
            equipment: equipment,
            targetRepMin: repMin,
            targetRepMax: repMax
        )
        context.insert(exercise)
        dismiss()
    }
}
