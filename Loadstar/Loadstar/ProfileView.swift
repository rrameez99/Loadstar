//
//  ProfileView.swift
//  Loadstar
//
//  Training profile and Health connection.
//
//  These aren't vanity fields. Banister's TRIMP formula needs heart-rate reserve
//  (resting and max HR) and applies a different exponential coefficient by sex.
//  Without them, strain can't be computed at all — so this screen is a prerequisite
//  for the load engine, not a settings afterthought.
//

import SwiftUI
import SwiftData
import HealthKit

// MARK: - Profile storage
//
// @AppStorage is UserDefaults with SwiftUI change tracking — the right tool for a
// handful of scalars that belong to the person rather than the training history.
// Anything that needs to be charted over time belongs in SwiftData instead.

enum ProfileKey {
    static let birthYear = "profile.birthYear"
    static let biologicalSex = "profile.biologicalSex"
    static let restingHR = "profile.restingHR"
    static let maxHR = "profile.maxHR"
    static let bodyMassKg = "profile.bodyMassKg"
    static let name = "profile.name"
    static let preferredUnit = "profile.preferredUnit"
}

// PreferredUnitDefaults lives in Units.swift, alongside the conversion and
// display rules it belongs with.

enum BiologicalSexOption: String, CaseIterable, Identifiable {
    case male, female, unspecified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male:        return "Male"
        case .female:      return "Female"
        case .unspecified: return "Prefer not to say"
        }
    }

    /// The exponential weighting constant in Banister's TRIMP model. The two
    /// values come from the original literature and reflect measured differences
    /// in the blood-lactate response to heart-rate reserve.
    var trimpCoefficient: Double {
        switch self {
        case .male:        return 1.92
        case .female:      return 1.67
        // Midpoint when unstated — better than silently assuming.
        case .unspecified: return 1.80
        }
    }
}

// MARK: - View

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(ProfileKey.name) private var name = ""
    @AppStorage(ProfileKey.birthYear) private var birthYear = 0
    @AppStorage(ProfileKey.biologicalSex) private var sexRaw = BiologicalSexOption.unspecified.rawValue
    @AppStorage(ProfileKey.restingHR) private var restingHR = 0
    @AppStorage(ProfileKey.maxHR) private var maxHR = 0
    @AppStorage(ProfileKey.bodyMassKg) private var bodyMassKg = 0.0
    @AppStorage(ProfileKey.preferredUnit) private var preferredUnitRaw = WeightUnit.pounds.rawValue

    @State private var health = HealthKitService.shared
    @State private var showingAuthError: String?

    @Query private var dailyMetrics: [DailyMetrics]

    private var sex: BiologicalSexOption {
        BiologicalSexOption(rawValue: sexRaw) ?? .unspecified
    }

    /// Age-predicted max HR using the Tanaka formula (208 − 0.7 × age), which is
    /// meaningfully more accurate than the familiar 220 − age, especially past 40.
    /// Only a fallback — a real measured max from a hard effort beats any formula.
    private var estimatedMaxHR: Int? {
        guard birthYear > 1900 else { return nil }
        let age = Calendar.current.component(.year, from: Date()) - birthYear
        guard age > 0, age < 120 else { return nil }
        return Int((208.0 - 0.7 * Double(age)).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Name", text: $name)

                    Picker("Sex", selection: $sexRaw) {
                        ForEach(BiologicalSexOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }

                    HStack {
                        Text("Birth year")
                        Spacer()
                        TextField("1999", value: $birthYear, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Body weight")
                        Spacer()
                        TextField("0", value: $bodyMassKg, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("kg").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Log weights in", selection: $preferredUnitRaw) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit == .pounds ? "Pounds (lb)" : "Kilograms (kg)")
                                .tag(unit.rawValue)
                        }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("New sets default to this, and totals, charts and estimated 1RMs are shown in it. Nothing already recorded changes — a session logged in kg stays logged in kg, and every comparison is normalised behind the scenes regardless of which gym you were in.")
                }

                Section {
                    HStack {
                        Text("Resting HR")
                        Spacer()
                        TextField("0", value: $restingHR, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("bpm").foregroundStyle(.secondary)
                    }

                    if let observed = observedRestingHR {
                        Button("Use \(observed) bpm from Health") {
                            restingHR = observed
                        }
                        .font(.callout)
                    }

                    HStack {
                        Text("Max HR")
                        Spacer()
                        TextField("0", value: $maxHR, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("bpm").foregroundStyle(.secondary)
                    }

                    if let estimate = estimatedMaxHR {
                        Button("Use age estimate of \(estimate) bpm") {
                            maxHR = estimate
                        }
                        .font(.callout)
                    }
                } header: {
                    Text("Heart rate")
                } footer: {
                    Text("Strain is computed from heart-rate reserve, so these two numbers set the scale for every training-load figure. The age estimate is a starting point — if you've seen a higher number on a hard effort, use that instead.")
                }

                Section {
                    if !health.isHealthDataAvailable {
                        Label("Not available on this device", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await connectHealth() }
                        } label: {
                            HStack {
                                Label("Connect Apple Health", systemImage: "heart.text.square")
                                Spacer()
                                if health.isSyncing { ProgressView() }
                            }
                        }
                        .disabled(health.isSyncing)

                        if let last = health.lastSyncDate {
                            LabeledContent(
                                "Last synced",
                                value: last.formatted(date: .abbreviated, time: .shortened)
                            )
                        }

                        LabeledContent("Days of data", value: "\(dailyMetrics.count)")
                    }

                    if let error = health.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Loadstar reads only — it never writes anything back to Health. Health data doesn't exist in the Simulator, so this needs to run on your iPhone.")
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Median resting HR from the last two weeks of synced data — median rather
    /// than mean because a single illness or bad night skews an average badly.
    private var observedRestingHR: Int? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let values = dailyMetrics
            .filter { $0.date >= cutoff }
            .compactMap(\.restingHeartRate)
            .sorted()

        guard !values.isEmpty else { return nil }
        return Int(values[values.count / 2].rounded())
    }

    private func connectHealth() async {
        do {
            try await health.requestAuthorization()
            // Full window on an explicit tap — this is the one place a slow,
            // thorough sync is worth it. Foreground refreshes only do 7 days.
            await health.sync(days: 60, into: context)
        } catch {
            health.lastError = error.localizedDescription
        }
    }
}
