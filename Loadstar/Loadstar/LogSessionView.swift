//
//  LogSessionView.swift
//  Loadstar
//
//  Shared logging components used by both today's session and any past session
//  opened from history. The session-browsing shell lives in WorkoutsView.
//

import SwiftUI
import SwiftData

// MARK: - Set row

struct SetRow: View {
    let entry: SetEntry
    let index: Int

    var body: some View {
        HStack {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            Text(entry.displayDescription)
                .font(.body.monospacedDigit())

            if entry.isWarmup {
                Text("warmup")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Spacer()

            if let rpe = entry.rpe {
                Text("RPE \(formatted(rpe))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Exercise picker

struct ExercisePickerView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    /// A closure passed in by the parent — the child doesn't know or care what
    /// happens with the selection. Standard SwiftUI pattern for child-to-parent
    /// communication.
    let onSelect: (Exercise) -> Void

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    onSelect(exercise)
                } label: {
                    ExerciseRow(exercise: exercise)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search exercises")
            .navigationTitle("Pick Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filtered: [Exercise] {
        guard !searchText.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Logging sets

struct LogSetsView: View {
    let exercise: Exercise
    let session: WorkoutSession
    let history: [SetEntry]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var weight: Double = 0
    @State private var reps: Int = 0
    @State private var unit: WeightUnit = .kilograms
    @State private var isPerSide = false
    @State private var barWeightKg: Double = 0
    @State private var isWarmup = false
    @State private var loggedThisVisit: [SetEntry] = []

    /// Collapsed-state summary for the loading controls, so the common case reads
    /// as "Total" at a glance and only the unusual case invites a tap.
    private var loadingSummary: String {
        switch (isPerSide, barWeightKg > 0) {
        case (true, true):   return "Per side + \(format(barWeightKg)) kg bar"
        case (true, false):  return "Per side"
        case (false, true):  return "\(format(barWeightKg)) kg bar"
        case (false, false): return "Total"
        }
    }

    /// What the current inputs work out to in total, shown live under the fields.
    private var previewBreakdown: String {
        guard isPerSide || barWeightKg > 0, weight > 0 else { return "" }
        let plates = weight * unit.toKilograms
        let total = (isPerSide ? plates * 2 : plates) + barWeightKg
        return "Total: \(format(total)) kg"
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recommended") {
                    let recommendation = ProgressionEngine.recommendation(for: exercise, history: history)
                    VStack(alignment: .leading, spacing: 4) {
                        if recommendation.targetWeight > 0 {
                            Text("\(recommendation.setCount) × \(recommendation.targetReps) @ \(recommendation.displayWeight)")
                                .font(.headline)
                        }
                        Text(recommendation.rationale.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("This set") {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("0", value: $weight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)

                        // Segmented rather than a wheel: switching units is rare but
                        // has to be obvious, because a wrong unit silently corrupts
                        // every downstream calculation.
                        Picker("Unit", selection: $unit) {
                            ForEach(WeightUnit.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 90)
                    }

                    Stepper("Reps: \(reps)", value: $reps, in: 0...50)
                    Toggle("Warmup set", isOn: $isWarmup)

                    // The computed total stays visible even though the controls
                    // that produce it are tucked away below. Hiding the inputs is
                    // fine; hiding the consequence is not.
                    if !previewBreakdown.isEmpty {
                        Text(previewBreakdown)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Log Set") { logSet() }
                        .disabled(reps == 0)
                }

                // Per-side and bar weight matter for a handful of movements, so
                // they're collapsed by default rather than cluttering every entry.
                // The label carries the current state so it's readable without
                // expanding.
                Section {
                    DisclosureGroup {
                        Toggle("Weight is per side", isOn: $isPerSide)

                        HStack {
                            Text("Bar weight")
                            Spacer()
                            TextField("0", value: $barWeightKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    } label: {
                        LabeledContent("Loading", value: loadingSummary)
                    }
                } footer: {
                    Text("Only needed for barbell lifts loaded with plates on each side.")
                }

                if !loggedThisVisit.isEmpty {
                    Section("Logged") {
                        ForEach(Array(loggedThisVisit.enumerated()), id: \.element.id) { index, entry in
                            SetRow(entry: entry, index: index + 1)
                        }
                    }
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    /// Seeds the fields with what the engine expects, so a normal set is one tap.
    private func prefill() {
        let recommendation = ProgressionEngine.recommendation(for: exercise, history: history)
        weight = recommendation.targetWeight
        reps = recommendation.targetReps
        unit = recommendation.unit
        isPerSide = recommendation.isPerSide
        barWeightKg = exercise.defaultBarWeightKg
    }

    private func logSet() {
        // Timestamp follows the session's date, not the wall clock — otherwise a
        // set added to last Tuesday's session while editing would land on today
        // and corrupt both days' load figures.
        let timestamp = Calendar.current.isDateInToday(session.date)
            ? Date()
            : session.date.addingTimeInterval(Double(session.sets.count) * 60)

        let entry = SetEntry(
            weight: weight,
            reps: reps,
            unit: unit,
            isPerSide: isPerSide,
            barWeightKg: barWeightKg,
            isWarmup: isWarmup,
            exercise: exercise,
            session: session,
            timestamp: timestamp
        )
        context.insert(entry)
        loggedThisVisit.append(entry)

        // Warmup stays on only for the set you marked it on — forgetting to toggle
        // it back off would quietly corrupt the load numbers.
        isWarmup = false
    }
}
