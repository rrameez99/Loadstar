//
//  HealthKitService.swift
//  Loadstar
//
//  Reads Apple Watch biometrics out of HealthKit and normalizes them into one row
//  per day. Everything downstream — recovery scoring, strain, trends — consumes
//  DailyMetrics, never HealthKit directly. That boundary is deliberate: it keeps
//  the analytics pure and unit-testable, and means a bad night of sensor data
//  degrades one row rather than crashing a chart.
//
//  Important: HealthKit returns nothing in the Simulator. This has to run on a
//  real iPhone paired to the watch.
//

import Foundation
import HealthKit
import SwiftData

// MARK: - Snapshot
//
// A plain value type, deliberately separate from the @Model. Queries run off the
// main actor and hand back one of these; only the final write touches SwiftData.

struct DailyMetricsSnapshot {
    var date: Date

    var hrvSDNN: Double?
    var restingHeartRate: Double?
    var respiratoryRate: Double?
    var wristTemperatureDelta: Double?
    var bloodOxygen: Double?
    var vo2Max: Double?

    var sleepDurationMinutes: Double?
    var deepSleepMinutes: Double?
    var remSleepMinutes: Double?
    var coreSleepMinutes: Double?
    var awakeMinutes: Double?
}

// MARK: - Errors

enum HealthKitError: LocalizedError {
    case unavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Health data isn't available on this device. HealthKit doesn't work in the Simulator."
        case .authorizationDenied:
            return "Loadstar doesn't have permission to read your health data. You can grant it in Settings › Health › Data Access & Devices."
        }
    }
}

// MARK: - Service

@Observable
final class HealthKitService {

    static let shared = HealthKitService()

    private let store = HKHealthStore()

    /// Whether the permission sheet has been shown. Note this is *not* the same as
    /// having data: HealthKit deliberately refuses to tell an app which read
    /// permissions were denied, so that an app can't infer anything from the
    /// absence of data. The only honest signal is whether queries return results.
    var hasRequestedAuthorization = false
    var lastSyncDate: Date?
    var lastError: String?
    var isSyncing = false

    private init() {}

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: Types

    /// Everything worth reading off an Apple Watch Ultra for training analytics.
    /// Quantity types that don't exist on a given watch simply return no samples.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
        ]

        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .respiratoryRate,
            .oxygenSaturation,
            .vo2Max,
            .activeEnergyBurned,
            .bodyMass,
            .appleSleepingWristTemperature,
        ]

        for identifier in quantityIdentifiers {
            types.insert(HKQuantityType(identifier))
        }

        return types
    }

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthKitError.unavailable }

        // Read-only. Loadstar analyzes what the watch already recorded and writes
        // nothing back, so there's no share set to request.
        try await store.requestAuthorization(toShare: [], read: readTypes)
        hasRequestedAuthorization = true
    }

    // MARK: Daily metrics

    /// Pulls one day's biometrics.
    ///
    /// Each metric uses the aggregation that matches how the watch records it:
    /// resting HR and VO2 max are already daily summaries, HRV is sampled many
    /// times so it gets averaged, and sleep needs stage-by-stage summing across a
    /// window that spans midnight.
    func fetchDailyMetrics(for date: Date) async -> DailyMetricsSnapshot {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        var snapshot = DailyMetricsSnapshot(date: dayStart)

        // HRV is measured repeatedly overnight; the daily average is the figure
        // that baselines are built from.
        snapshot.hrvSDNN = await average(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            from: dayStart, to: dayEnd
        )

        snapshot.restingHeartRate = await average(
            .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            from: dayStart, to: dayEnd
        )

        snapshot.respiratoryRate = await average(
            .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            from: dayStart, to: dayEnd
        )

        // Already a deviation from your own baseline, not an absolute temperature.
        snapshot.wristTemperatureDelta = await average(
            .appleSleepingWristTemperature,
            unit: .degreeCelsius(),
            from: dayStart, to: dayEnd
        )

        snapshot.bloodOxygen = await average(
            .oxygenSaturation,
            unit: .percent(),
            from: dayStart, to: dayEnd
        )

        // VO2 max updates every few weeks, so a strict same-day query usually
        // returns nothing. Look back 30 days and take the most recent value.
        snapshot.vo2Max = await mostRecent(
            .vo2Max,
            unit: HKUnit(from: "ml/kg*min"),
            endingAt: dayEnd,
            lookbackDays: 30
        )

        if let sleep = await fetchSleep(forNightEnding: dayEnd) {
            snapshot.sleepDurationMinutes = sleep.asleepMinutes
            snapshot.deepSleepMinutes = sleep.deepMinutes
            snapshot.remSleepMinutes = sleep.remMinutes
            snapshot.coreSleepMinutes = sleep.coreMinutes
            snapshot.awakeMinutes = sleep.awakeMinutes
        }

        return snapshot
    }

    // MARK: Quantity helpers

    private func average(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, _ in
                let value = statistics?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func mostRecent(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        endingAt end: Date,
        lookbackDays: Int
    ) async -> Double? {
        let type = HKQuantityType(identifier)
        let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    // MARK: Sleep

    private struct SleepSummary {
        var asleepMinutes: Double
        var deepMinutes: Double
        var remMinutes: Double
        var coreMinutes: Double
        var awakeMinutes: Double
    }

    /// Sums sleep stages for the night *ending* on the given morning.
    ///
    /// The window runs 6pm the previous evening to noon, because sleep crosses
    /// midnight and a naive same-calendar-day query would split every night in two
    /// and report roughly half the real duration.
    private func fetchSleep(forNightEnding morning: Date) async -> SleepSummary? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: morning)

        guard
            let windowStart = calendar.date(byAdding: .hour, value: -6, to: dayStart),
            let windowEnd = calendar.date(byAdding: .hour, value: 12, to: dayStart)
        else { return nil }

        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        guard !samples.isEmpty else { return nil }

        var summary = SleepSummary(
            asleepMinutes: 0, deepMinutes: 0, remMinutes: 0, coreMinutes: 0, awakeMinutes: 0
        )

        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60

            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepDeep:
                summary.deepMinutes += minutes
                summary.asleepMinutes += minutes
            case .asleepREM:
                summary.remMinutes += minutes
                summary.asleepMinutes += minutes
            case .asleepCore:
                summary.coreMinutes += minutes
                summary.asleepMinutes += minutes
            case .asleepUnspecified:
                // Older watches and third-party trackers report undifferentiated
                // sleep. It counts toward duration but not toward any stage.
                summary.asleepMinutes += minutes
            case .awake:
                summary.awakeMinutes += minutes
            case .inBed, .none:
                // "In bed" overlaps the stage samples, so counting it would
                // double-count the whole night.
                break
            @unknown default:
                break
            }
        }

        return summary
    }

    // MARK: Sync

    /// Pulls the last `days` days into SwiftData, updating existing rows in place.
    ///
    /// Runs the full window rather than only new days because HealthKit backfills:
    /// sleep staging and resting HR for a given night often don't finalize until
    /// hours later, so a row written this morning may be incomplete.
    @MainActor
    func sync(days: Int = 60, into context: ModelContext) async {
        guard isHealthDataAvailable else {
            lastError = HealthKitError.unavailable.errorDescription
            return
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Fetch existing rows once and index them, rather than issuing a query per
        // day inside the loop.
        let existing = (try? context.fetch(FetchDescriptor<DailyMetrics>())) ?? []
        var byDate: [Date: DailyMetrics] = [:]
        for row in existing {
            byDate[calendar.startOfDay(for: row.date)] = row
        }

        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }

            let snapshot = await fetchDailyMetrics(for: day)

            // Skip days with nothing at all — before you owned the watch, or days
            // it wasn't worn. Writing empty rows would pollute the baselines.
            let hasAnyData = snapshot.hrvSDNN != nil
                || snapshot.restingHeartRate != nil
                || snapshot.sleepDurationMinutes != nil
            guard hasAnyData else { continue }

            let row = byDate[snapshot.date] ?? {
                let created = DailyMetrics(date: snapshot.date)
                context.insert(created)
                byDate[snapshot.date] = created
                return created
            }()

            row.hrvSDNN = snapshot.hrvSDNN
            row.restingHeartRate = snapshot.restingHeartRate
            row.respiratoryRate = snapshot.respiratoryRate
            row.wristTemperatureDelta = snapshot.wristTemperatureDelta
            row.bloodOxygen = snapshot.bloodOxygen
            row.vo2Max = snapshot.vo2Max
            row.sleepDurationMinutes = snapshot.sleepDurationMinutes
            row.deepSleepMinutes = snapshot.deepSleepMinutes
            row.remSleepMinutes = snapshot.remSleepMinutes
            row.coreSleepMinutes = snapshot.coreSleepMinutes
            row.awakeMinutes = snapshot.awakeMinutes
            row.lastComputed = Date()
        }

        try? context.save()
        lastSyncDate = Date()
    }
}
