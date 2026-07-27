//
//  ExerciseEditor.swift
//  Loadstar
//
//  One form for both creating and editing an exercise.
//
//  It edits a value-type draft rather than binding straight to the model, which
//  is the opposite of what EditSetView does. That's deliberate: a set has two
//  fields and live-writing is fine, but an exercise carries a dozen settings that
//  reshape every future prescription. Getting halfway through changing the bar
//  weight and rep range, then backing out, should leave the exercise untouched.
//  Binding directly to the model gives you no way to cancel.
//

import SwiftUI
import SwiftData

// MARK: - Draft

struct ExerciseDraft {
    var name: String = ""
    var primaryMuscle: MuscleGroup = .chest
    var secondaryMuscles: [MuscleGroup] = []
    var equipment: Equipment = .barbell

    var targetRepMin: Int = 8
    var targetRepMax: Int = 12
    var defaultSetCount: Int = 3
    var weightIncrement: Double = 5

    var defaultUnit: WeightUnit = .kilograms
    var defaultIsPerSide: Bool = false
    var defaultBarWeightKg: Double = 0

    var restSeconds: Int = 120
    var notes: String = ""

    init() {
        // A brand-new exercise should follow whatever unit you're currently
        // logging in, not a hardcoded default.
        defaultUnit = PreferredUnitDefaults.current
    }

    init(from exercise: Exercise) {
        name = exercise.name
        primaryMuscle = exercise.primaryMuscle
        secondaryMuscles = exercise.secondaryMuscles
        equipment = exercise.equipment
        targetRepMin = exercise.targetRepMin
        targetRepMax = exercise.targetRepMax
        defaultSetCount = exercise.defaultSetCount
        weightIncrement = exercise.weightIncrement
        defaultUnit = exercise.defaultUnit
        defaultIsPerSide = exercise.defaultIsPerSide
        defaultBarWeightKg = exercise.defaultBarWeightKg
        restSeconds = exercise.restSeconds
        notes = exercise.notes
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedName.isEmpty && targetRepMin <= targetRepMax
    }

    func apply(to exercise: Exercise) {
        exercise.name = trimmedName
        exercise.primaryMuscle = primaryMuscle
        // A muscle listed as both primary and secondary would be double-counted
        // in every volume calculation.
        exercise.secondaryMuscles = secondaryMuscles.filter { $0 != primaryMuscle }
        exercise.equipment = equipment
        exercise.targetRepMin = targetRepMin
        exercise.targetRepMax = targetRepMax
        exercise.defaultSetCount = defaultSetCount
        exercise.weightIncrement = weightIncrement
        exercise.defaultUnit = defaultUnit
        exercise.defaultIsPerSide = defaultIsPerSide
        exercise.defaultBarWeightKg = defaultBarWeightKg
        exercise.restSeconds = restSeconds
        exercise.notes = notes
    }

    func makeExercise() -> Exercise {
        let exercise = Exercise(
            name: trimmedName,
            primaryMuscle: primaryMuscle,
            secondaryMuscles: secondaryMuscles.filter { $0 != primaryMuscle },
            equipment: equipment,
            targetRepMin: targetRepMin,
            targetRepMax: targetRepMax,
            weightIncrement: weightIncrement,
            defaultSetCount: defaultSetCount,
            defaultUnit: defaultUnit,
            defaultIsPerSide: defaultIsPerSide,
            defaultBarWeightKg: defaultBarWeightKg,
            restSeconds: restSeconds,
            notes: notes
        )
        return exercise
    }
}

// MARK: - Editor

struct ExerciseEditorView: View {
    /// Nil means we're creating a new exercise.
    let existing: Exercise?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allExercises: [Exercise]

    @State private var draft: ExerciseDraft
    @State private var showingDeleteConfirmation = false

    // Reading properties off a @Model is main-actor isolated, and a struct's
    // init is nonisolated by default — so this has to be marked explicitly.
    @MainActor
    init(existing: Exercise? = nil) {
        self.existing = existing
        _draft = State(initialValue: existing.map(ExerciseDraft.init(from:)) ?? ExerciseDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $draft.name)

                    if nameCollides {
                        Label("Another exercise already uses this name.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Classification") {
                    Picker("Primary muscle", selection: $draft.primaryMuscle) {
                        ForEach(MuscleGroup.allCases) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }

                    NavigationLink {
                        SecondaryMusclePicker(
                            selected: $draft.secondaryMuscles,
                            excluding: draft.primaryMuscle
                        )
                    } label: {
                        LabeledContent("Secondary", value: secondarySummary)
                    }

                    Picker("Equipment", selection: $draft.equipment) {
                        ForEach(Equipment.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }

                Section {
                    Stepper("Minimum reps: \(draft.targetRepMin)", value: $draft.targetRepMin, in: 1...50)
                    Stepper("Maximum reps: \(draft.targetRepMax)", value: $draft.targetRepMax, in: 1...50)
                    Stepper("Working sets: \(draft.defaultSetCount)", value: $draft.defaultSetCount, in: 1...10)

                    HStack {
                        Text("Weight increment")
                        Spacer()
                        DecimalField(placeholder: "5", value: $draft.weightIncrement)
                        Text(draft.defaultUnit.displayName).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Progression")
                } footer: {
                    if draft.targetRepMin > draft.targetRepMax {
                        Text("Minimum can't be higher than maximum.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Clear \(draft.targetRepMax) reps on every working set and the app adds \(formatted(draft.weightIncrement)) \(draft.defaultUnit.displayName), dropping you back to \(draft.targetRepMin).")
                    }
                }

                Section {
                    Picker("Log in", selection: $draft.defaultUnit) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit == .pounds ? "Pounds (lb)" : "Kilograms (kg)").tag(unit)
                        }
                    }

                    Toggle("Weight is per side", isOn: $draft.defaultIsPerSide)

                    HStack {
                        Text("Bar weight")
                        Spacer()
                        DecimalField(placeholder: "0", value: $draft.defaultBarWeightKg.inDisplayUnit())
                        Text(DisplayUnit.symbol).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Loading")
                } footer: {
                    Text(loadingExplanation)
                }

                Section {
                    Stepper(
                        "Rest: \(draft.restSeconds / 60):\(String(format: "%02d", draft.restSeconds % 60))",
                        value: $draft.restSeconds,
                        in: 15...600,
                        step: 15
                    )
                } header: {
                    Text("Rest")
                }

                Section("Notes") {
                    TextField("Form cues, machine settings, seat height…", text: $draft.notes, axis: .vertical)
                        .lineLimit(1...5)
                }

                if existing != nil {
                    Section {
                        Button("Delete Exercise", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } footer: {
                        // Worth stating plainly, because the opposite would be the
                        // reasonable fear.
                        Text("Your logged sets are kept. They stay in your history and session totals, just without a link back to this exercise.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Exercise" : "Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.isValid || nameCollides)
                }
            }
            .confirmationDialog(
                "Delete \(draft.trimmedName)?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Exercise", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes it from your library. Sets you've already logged are kept.")
            }
        }
    }

    // MARK: Derived

    /// `Exercise.name` carries a uniqueness constraint, so saving a duplicate
    /// would crash rather than fail gracefully. Catch it in the UI instead.
    private var nameCollides: Bool {
        let candidate = draft.trimmedName.lowercased()
        guard !candidate.isEmpty else { return false }
        return allExercises.contains {
            $0.name.lowercased() == candidate && $0.persistentModelID != existing?.persistentModelID
        }
    }

    private var secondarySummary: String {
        let filtered = draft.secondaryMuscles.filter { $0 != draft.primaryMuscle }
        return filtered.isEmpty ? "None" : filtered.map(\.displayName).joined(separator: ", ")
    }

    private var loadingExplanation: String {
        switch (draft.defaultIsPerSide, draft.defaultBarWeightKg > 0) {
        case (true, true):
            return "Entering 25 records 25 per side plus a \(DisplayUnit.weight(draft.defaultBarWeightKg)) bar — \(DisplayUnit.weight(25 * 2 * draft.defaultUnit.toKilograms + draft.defaultBarWeightKg)) total."
        case (true, false):
            return "Entering 25 records 25 per side, so 50 total. Right for dumbbells and plate-loaded machines."
        case (false, true):
            return "A \(DisplayUnit.weight(draft.defaultBarWeightKg)) bar is added to whatever you enter."
        case (false, false):
            return "The number you enter is the total lifted. Right for cable stacks and most machines."
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Actions

    private func save() {
        if let existing {
            draft.apply(to: existing)
        } else {
            context.insert(draft.makeExercise())
        }
        dismiss()
    }

    private func delete() {
        guard let existing else { return }
        // The relationship uses .nullify, so this orphans the sets rather than
        // cascading — months of history shouldn't vanish because a library entry
        // was tidied up.
        context.delete(existing)
        dismiss()
    }
}

// MARK: - Secondary muscle picker

struct SecondaryMusclePicker: View {
    @Binding var selected: [MuscleGroup]
    let excluding: MuscleGroup

    var body: some View {
        List {
            Section {
                ForEach(MuscleGroup.allCases.filter { $0 != excluding }) { muscle in
                    Button {
                        toggle(muscle)
                    } label: {
                        HStack {
                            Text(muscle.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(muscle) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                Text("Secondary muscles receive half credit in volume calculations. Rows train back fully and biceps partially.")
            }
        }
        .navigationTitle("Secondary Muscles")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ muscle: MuscleGroup) {
        if let index = selected.firstIndex(of: muscle) {
            selected.remove(at: index)
        } else {
            selected.append(muscle)
        }
    }
}
