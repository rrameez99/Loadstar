//
//  TodayView.swift
//  Loadstar
//
//  The dashboard. Three rings, one sentence of interpretation, and a tap-through
//  to the arithmetic behind each number.
//
//  The design constraint that separates this from the apps it's imitating: every
//  score expands into its inputs. Whoop shows you 65% and asks you to trust it.
//  Here, 65% opens to "HRV 48 ms against a 57 ms baseline, z = −1.2, weighted 40%."
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \DailyMetrics.date, order: .reverse) private var metrics: [DailyMetrics]
    @Query private var allSets: [SetEntry]

    @AppStorage(ProfileKey.restingHR) private var restingHR = 0
    @AppStorage(ProfileKey.maxHR) private var maxHR = 0
    @AppStorage(ProfileKey.bodyMassKg) private var bodyMassKg = 0.0
    @AppStorage(ProfileKey.biologicalSex) private var sexRaw = BiologicalSexOption.unspecified.rawValue

    @State private var showingProfile = false
    @State private var detail: ScoreDetail?

    enum ScoreDetail: String, Identifiable {
        case sleep, recovery, strain
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if today == nil {
                        emptyState
                    } else {
                        ringRow
                        insightCard
                        loadCard
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingProfile = true
                    } label: {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(item: $detail) { which in
                ScoreDetailView(
                    kind: which,
                    recovery: recovery,
                    strain: strain,
                    day: today
                )
            }
        }
    }

    // MARK: - Rings

    private var ringRow: some View {
        HStack(spacing: 12) {
            RingView(
                title: "Sleep",
                value: recovery?.sleepScore,
                display: recovery?.sleepScore.map { "\(Int($0))%" } ?? "—",
                progress: (recovery?.sleepScore ?? 0) / 100,
                tint: .cyan
            )
            .onTapGesture { detail = .sleep }

            RingView(
                title: "Recovery",
                value: recovery?.score,
                display: recovery.map { "\(Int($0.score))%" } ?? "—",
                progress: (recovery?.score ?? 0) / 100,
                tint: recoveryTint
            )
            .onTapGesture { detail = .recovery }

            RingView(
                title: "Strain",
                value: strain?.strain,
                display: strain.map { String(format: "%.1f", $0.strain) } ?? "—",
                progress: (strain?.strain ?? 0) / StrainEngine.maxStrain,
                tint: .blue
            )
            .onTapGesture { detail = .strain }
        }
    }

    private var recoveryTint: Color {
        switch recovery?.band {
        case .high:     return .green
        case .moderate: return .yellow
        case .low:      return .red
        case nil:       return .gray
        }
    }

    // MARK: - Insight

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recovery {
                Text(headline(for: recovery))
                    .font(.headline)

                Text(recovery.band.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let driver = recovery.dominantDriver {
                    Divider().padding(.vertical, 2)
                    Text("Biggest factor: \(driver.name) is \(driver.deviationDescription).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Building your baseline")
                    .font(.headline)
                Text("Recovery scoring needs at least \(RecoveryEngine.minimumBaselineDays) days of history before the numbers mean anything. You have \(metrics.count).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Names the dominant driver rather than restating the band, so the sentence
    /// carries information the ring doesn't already show.
    private func headline(for result: RecoveryResult) -> String {
        guard let driver = result.dominantDriver else {
            return "\(result.band.rawValue) recovery"
        }

        let verb = driver.isFavourable ? "elevated" : "suppressed"
        return "\(driver.name) \(verb) — \(result.band.rawValue.lowercased()) recovery"
    }

    // MARK: - Load card

    private var loadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Training load")
                .font(.headline)

            if let strain {
                if let share = strain.mechanicalShare, strain.hasMechanical {
                    // The differentiator, stated plainly.
                    HStack {
                        Text("From lifting")
                        Spacer()
                        Text("\(Int(share * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    Text("A heart-rate-only model would have missed most of this — HR sits near resting between sets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if strain.hasCardio {
                    HStack {
                        Text("Cardiovascular (TRIMP)")
                        Spacer()
                        Text(String(format: "%.0f", strain.cardiovascularLoad))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            // Neither channel has anything and there's no ratio yet — say so
            // plainly rather than leaving an empty card that looks broken.
            if (strain?.cardiovascularLoad ?? 0) == 0,
               (strain?.mechanicalLoad ?? 0) == 0,
               acwr == nil {
                Text("Nothing logged today, and no workout picked up from Apple Health. Log a session and this fills in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let ratio = acwr {
                Divider()
                let zone = StrainEngine.zone(for: ratio)
                HStack {
                    Text("Acute:chronic ratio")
                    Spacer()
                    Text(String(format: "%.2f", ratio))
                        .foregroundStyle(acwrTint(zone))
                        .fontWeight(.semibold)
                }
                .font(.callout)

                Text(zone.guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func acwrTint(_ zone: StrainEngine.ACWRZone) -> Color {
        switch zone {
        case .optimal:     return .green
        case .caution:     return .orange
        case .highRisk:    return .red
        case .detraining:  return .secondary
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No health data yet", systemImage: "waveform.path.ecg")
        } description: {
            Text("Connect Apple Health in your profile to pull in Apple Watch data.")
        } actions: {
            Button("Open Profile") { showingProfile = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }

    // MARK: - Computed scores

    private var today: DailyMetrics? { metrics.first }

    private var recovery: RecoveryResult? {
        guard let today else { return nil }
        return RecoveryEngine.recovery(for: today, history: metrics)
    }

    private var strain: StrainResult? {
        guard let today else { return nil }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: today.date)
        let volume = allSets
            .filter { !$0.isWarmup && calendar.startOfDay(for: $0.timestamp) == dayStart }
            .reduce(0) { $0 + $1.volumeLoad }

        // Cardiovascular load was computed at ingest; only mechanical load is
        // recomputed here, since sets can be logged after the last sync.
        let mechanical = StrainEngine.mechanicalLoad(
            volumeKg: volume,
            bodyMassKg: bodyMassKg > 0 ? bodyMassKg : 70
        )
        let cardio = today.cardiovascularLoad ?? 0
        let total = cardio + mechanical

        return StrainResult(
            strain: (StrainEngine.maxStrain * (1 - exp(-total / StrainEngine.strainSaturationConstant)))
                .clamped(to: 0...StrainEngine.maxStrain),
            cardiovascularLoad: cardio,
            mechanicalLoad: mechanical,
            rawVolumeKg: volume
        )
    }

    private var acwr: Double? {
        let calendar = Calendar.current
        let mass = bodyMassKg > 0 ? bodyMassKg : 70

        // One combined load figure per day, from both channels.
        var loads: [Date: Double] = [:]

        for day in metrics {
            loads[calendar.startOfDay(for: day.date), default: 0] += day.cardiovascularLoad ?? 0
        }

        for entry in allSets where !entry.isWarmup {
            let day = calendar.startOfDay(for: entry.timestamp)
            loads[day, default: 0] += StrainEngine.mechanicalLoad(
                volumeKg: entry.volumeLoad,
                bodyMassKg: mass
            )
        }

        let series = loads.map { (date: $0.key, load: $0.value) }
        return StrainEngine.acuteChronicRatio(dailyLoads: series, asOf: Date())
    }
}

// MARK: - Ring

struct RingView: View {
    let title: String
    let value: Double?
    let display: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 8)

                Circle()
                    .trim(from: 0, to: max(0, min(progress, 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    // Start the arc at 12 o'clock rather than 3.
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: progress)

                Text(display)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(height: 96)

            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Score detail
//
// The "show your work" screen. This is the part the commercial apps don't have,
// and the reason the engines return their components rather than just a number.

struct ScoreDetailView: View {
    let kind: TodayView.ScoreDetail
    let recovery: RecoveryResult?
    let strain: StrainResult?
    let day: DailyMetrics?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .recovery: recoverySections
                case .sleep:    sleepSections
                case .strain:   strainSections
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        switch kind {
        case .recovery: return "Recovery"
        case .sleep:    return "Sleep"
        case .strain:   return "Strain"
        }
    }

    @ViewBuilder
    private var recoverySections: some View {
        if let recovery {
            Section {
                LabeledContent("Score", value: "\(Int(recovery.score))%")
                    .font(.body.weight(.semibold))
                LabeledContent("Band", value: recovery.band.rawValue)
                LabeledContent("Baseline", value: "\(recovery.baselineDays) days")
            } footer: {
                Text(recovery.band.guidance)
            }

            Section {
                ForEach(recovery.components) { component in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(component.name)
                            Spacer()
                            Text("\(Int(component.contribution))/100")
                                .foregroundStyle(component.isFavourable ? .green : .orange)
                                .monospacedDigit()
                        }

                        Text(component.deviationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text("z = \(String(format: "%+.2f", component.zScore))")
                            Text("weight \(Int(component.weight * 100))%")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Each metric is scored against your own 60-day rolling baseline, where z is how many standard deviations today sits from your normal. A missing sensor reweights the rest rather than dragging the score down.")
            }
        } else {
            ContentUnavailableView(
                "Not enough history",
                systemImage: "calendar.badge.clock",
                description: Text("Recovery needs \(RecoveryEngine.minimumBaselineDays) days of data before a baseline is meaningful.")
            )
        }
    }

    @ViewBuilder
    private var sleepSections: some View {
        if let day {
            Section("Last night") {
                sleepRow("Time asleep", day.sleepDurationMinutes)
                sleepRow("Deep", day.deepSleepMinutes)
                sleepRow("REM", day.remSleepMinutes)
                sleepRow("Core", day.coreSleepMinutes)
                sleepRow("Awake", day.awakeMinutes)

                if let efficiency = day.sleepEfficiency {
                    LabeledContent("Efficiency", value: "\(Int(efficiency * 100))%")
                }
            }

            if let score = recovery?.sleepScore {
                Section {
                    LabeledContent("Sleep score", value: "\(Int(score))%")
                        .font(.body.weight(.semibold))
                } footer: {
                    Text("Time asleep against a \(Int(RecoveryEngine.sleepNeedHours))-hour need, scaled down if efficiency fell below 85%. Scored against an absolute target rather than your own average — a baseline would quietly reward you for being reliably underslept.")
                }
            }
        }
    }

    @ViewBuilder
    private func sleepRow(_ label: String, _ minutes: Double?) -> some View {
        if let minutes {
            let hours = Int(minutes) / 60
            let mins = Int(minutes) % 60
            LabeledContent(label, value: "\(hours)h \(mins)m")
        }
    }

    @ViewBuilder
    private var strainSections: some View {
        if let strain {
            Section {
                LabeledContent("Strain", value: String(format: "%.1f", strain.strain))
                    .font(.body.weight(.semibold))
                LabeledContent("Band", value: strain.band.rawValue)
            } footer: {
                Text("A 0–21 scale where load saturates rather than scaling linearly, so the range is spent on the difference between easy and moderate days rather than on extremes.")
            }

            Section {
                LabeledContent("Cardiovascular", value: String(format: "%.0f", strain.cardiovascularLoad))
                LabeledContent("Mechanical", value: String(format: "%.0f", strain.mechanicalLoad))
                LabeledContent("Volume lifted", value: "\(Int(strain.rawVolumeKg)) kg")

                if let share = strain.mechanicalShare {
                    LabeledContent("Lifting share", value: "\(Int(share * 100))%")
                }
            } header: {
                Text("Load channels")
            } footer: {
                Text("Cardiovascular load is Banister TRIMP from workout heart rate. Mechanical load is volume normalized to body weight — the channel heart-rate-only apps miss entirely, because heart rate returns near resting between sets.")
            }
        }
    }
}
