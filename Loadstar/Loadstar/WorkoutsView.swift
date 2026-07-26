//
//  WorkoutsView.swift
//  Loadstar
//
//  Logging and history in one place, because they're the same thing viewed at
//  different distances. Today's session sits at the top for the daily action;
//  everything before it is a browsable, editable record.
//
//  The requirement driving this: charts are derived data, and derived data is
//  only trustworthy if you can get back to the raw entries behind it. Every set
//  here is reachable and correctable.
//

import SwiftUI
import SwiftData

struct WorkoutsView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var allSets: [SetEntry]

    @State private var pickingExercise = false
    @State private var loggingFor: Exercise?

    var body: some View {
        NavigationStack {
            List {
                todaySection
                historySection
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pickingExercise = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePickerView { exercise in
                    pickingExercise = false
                    loggingFor = exercise
                }
            }
            .sheet(item: $loggingFor) { exercise in
                LogSetsView(exercise: exercise, session: sessionForToday(), history: allSets)
            }
        }
    }

    // MARK: - Today

    @ViewBuilder
    private var todaySection: some View {
        Section("Today") {
            if let session = todaysSession, !session.sets.isEmpty {
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    SessionSummaryRow(session: session, showDate: false)
                }
            } else {
                Button {
                    pickingExercise = true
                } label: {
                    Label("Start logging", systemImage: "plus.circle")
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        let past = sessions.filter { session in
            !Calendar.current.isDateInToday(session.date) && !session.sets.isEmpty
        }

        if past.isEmpty {
            Section("History") {
                Text("Past sessions will appear here.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } else {
            // Grouped by month so a year of training stays navigable.
            ForEach(monthGroups(past), id: \.key) { group in
                Section(group.key) {
                    ForEach(group.sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionSummaryRow(session: session, showDate: true)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            // Cascade delete removes the sets with it — that rule
                            // is set on the relationship in Models.swift.
                            context.delete(group.sessions[index])
                        }
                    }
                }
            }
        }
    }

    private struct MonthGroup {
        let key: String
        let sessions: [WorkoutSession]
    }

    private func monthGroups(_ sessions: [WorkoutSession]) -> [MonthGroup] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        var order: [String] = []
        var buckets: [String: [WorkoutSession]] = [:]

        for session in sessions {
            let key = formatter.string(from: session.date)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(session)
        }

        return order.map { MonthGroup(key: $0, sessions: buckets[$0] ?? []) }
    }

    // MARK: - Helpers

    private var todaysSession: WorkoutSession? {
        sessions.first { Calendar.current.isDateInToday($0.date) }
    }

    private func sessionForToday() -> WorkoutSession {
        if let existing = todaysSession { return existing }
        let session = WorkoutSession(date: Date())
        context.insert(session)
        return session
    }
}

// MARK: - Summary row

struct SessionSummaryRow: View {
    let session: WorkoutSession
    let showDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showDate {
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.body.weight(.medium))
            }

            Text(exerciseNames)
                .font(showDate ? .caption : .body)
                .foregroundStyle(showDate ? .secondary : .primary)
                .lineLimit(2)

            Text("\(session.workingSets.count) sets · \(Int(session.totalVolumeLoad)) kg")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var exerciseNames: String {
        var seen: [String] = []
        for entry in session.sets.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let name = entry.exercise?.name, !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen.isEmpty ? "No exercises" : seen.joined(separator: ", ")
    }
}

// MARK: - Session detail

struct SessionDetailView: View {
    @Bindable var session: WorkoutSession

    @Environment(\.modelContext) private var context
    @Query private var allSets: [SetEntry]

    @State private var editingEntry: SetEntry?
    @State private var pickingExercise = false
    @State private var loggingFor: Exercise?
    @State private var editingDate = false

    var body: some View {
        List {
            Section {
                if editingDate {
                    DatePicker(
                        "Date",
                        selection: $session.date,
                        displayedComponents: .date
                    )
                } else {
                    Button {
                        editingDate = true
                    } label: {
                        LabeledContent("Date") {
                            Text(session.date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .foregroundStyle(.primary)
                }

                TextField("Notes", text: $session.notes, axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                // Logging a day late is common enough that fixing the date needs
                // to be possible — otherwise the set lands on the wrong day and
                // quietly distorts every load calculation downstream.
                Text("Tap the date to correct it if you logged this session late.")
            }

            ForEach(exerciseGroups, id: \.exerciseName) { group in
                Section {
                    ForEach(Array(group.sets.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            SetRow(entry: entry, index: index + 1)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            context.delete(group.sets[index])
                        }
                    }
                } header: {
                    Text(group.exerciseName)
                } footer: {
                    Text("\(Int(group.volume)) kg volume")
                }
            }

            Section {
                LabeledContent("Session volume", value: "\(Int(session.totalVolumeLoad)) kg")
                    .font(.body.weight(.semibold))
                LabeledContent("Working sets", value: "\(session.workingSets.count)")
            }
        }
        .navigationTitle(Calendar.current.isDateInToday(session.date)
                         ? "Today"
                         : session.date.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pickingExercise = true
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditSetView(entry: entry)
        }
        .sheet(isPresented: $pickingExercise) {
            ExercisePickerView { exercise in
                pickingExercise = false
                loggingFor = exercise
            }
        }
        .sheet(item: $loggingFor) { exercise in
            LogSetsView(exercise: exercise, session: session, history: allSets)
        }
    }

    private struct ExerciseGroup {
        let exerciseName: String
        let sets: [SetEntry]
        var volume: Double { sets.reduce(0) { $0 + $1.volumeLoad } }
    }

    private var exerciseGroups: [ExerciseGroup] {
        let ordered = session.sets.sorted { $0.timestamp < $1.timestamp }
        var names: [String] = []
        var buckets: [String: [SetEntry]] = [:]

        for entry in ordered {
            let name = entry.exercise?.name ?? "Unknown"
            if buckets[name] == nil {
                names.append(name)
                buckets[name] = []
            }
            buckets[name]?.append(entry)
        }

        return names.map { ExerciseGroup(exerciseName: $0, sets: buckets[$0] ?? []) }
    }
}

// MARK: - Edit a single set

struct EditSetView: View {
    /// `@Bindable` gives two-way bindings straight into a SwiftData model, so
    /// edits are live — no local copy to reconcile, no save button to forget.
    /// The trade-off is there's no cancel, which is why the destructive action
    /// here is an explicit Delete rather than an accidental swipe.
    @Bindable var entry: SetEntry

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            Form {
                Section("Weight") {
                    HStack {
                        TextField("0", value: $entry.weight, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 90)

                        Picker("Unit", selection: $entry.unit) {
                            ForEach(WeightUnit.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }

                    Stepper("Reps: \(entry.reps)", value: $entry.reps, in: 0...50)
                }

                Section {
                    Toggle("Weight is per side", isOn: $entry.isPerSide)

                    HStack {
                        Text("Bar weight")
                        Spacer()
                        TextField("0", value: $entry.barWeightKg, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("kg").foregroundStyle(.secondary)
                    }

                    Toggle("Warmup set", isOn: $entry.isWarmup)
                } header: {
                    Text("Loading")
                } footer: {
                    Text("Total: \(format(entry.totalWeightKg)) kg · volume \(Int(entry.volumeLoad)) kg")
                }

                Section {
                    DatePicker("Logged at", selection: $entry.timestamp)
                }

                Section {
                    Button("Delete Set", role: .destructive) {
                        context.delete(entry)
                        dismiss()
                    }
                }
            }
            .navigationTitle(entry.exercise?.name ?? "Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
