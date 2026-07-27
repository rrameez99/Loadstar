//
//  VitalsEngine.swift
//  Loadstar
//
//  Overnight vitals against your own normal range.
//
//  Distinct from RecoveryEngine on purpose. Recovery answers "how hard can I
//  train today" and weights its inputs toward that question. This answers "is
//  anything unusual", weights nothing, and includes metrics recovery ignores —
//  SpO2, wrist temperature, VO2 max. A metric can be perfectly normal and still
//  drag recovery down, and it can be flagged here without moving recovery at all.
//
//  Pure functions over DailyMetrics, no framework dependencies.
//

import Foundation

// MARK: - Reading

struct VitalReading: Identifiable {
    let id = UUID()
    let metric: Metric
    let value: Double
    let baseline: Double?
    let zScore: Double?

    enum Metric: String, CaseIterable {
        case restingHeartRate
        case hrv
        case respiratoryRate
        case bloodOxygen
        case wristTemperature

        var displayName: String {
            switch self {
            case .restingHeartRate: return "Resting HR"
            case .hrv:              return "HRV"
            case .respiratoryRate:  return "Respiratory rate"
            case .bloodOxygen:      return "Blood oxygen"
            case .wristTemperature: return "Wrist temp"
            }
        }

        var unit: String {
            switch self {
            case .restingHeartRate: return "bpm"
            case .hrv:              return "ms"
            case .respiratoryRate:  return "br/min"
            case .bloodOxygen:      return "%"
            case .wristTemperature: return "°C"
            }
        }

        var symbol: String {
            switch self {
            case .restingHeartRate: return "heart.fill"
            case .hrv:              return "waveform.path.ecg"
            case .respiratoryRate:  return "lungs.fill"
            case .bloodOxygen:      return "drop.fill"
            case .wristTemperature: return "thermometer.medium"
            }
        }

        /// Whether an *elevated* reading is the concerning direction. HRV is the
        /// only one here where high is good.
        var elevatedIsConcerning: Bool {
            self != .hrv
        }

        var decimals: Int {
            switch self {
            case .restingHeartRate, .respiratoryRate: return 0
            case .hrv:                                return 0
            case .bloodOxygen:                        return 0
            case .wristTemperature:                   return 1
            }
        }
    }

    /// Outside roughly the middle 87% of your own readings.
    ///
    /// 1.5σ rather than 2σ because this is meant to notice things early — the
    /// cost of an occasional "worth watching" is much lower than the cost of
    /// missing a genuine change. It is emphatically not a diagnosis.
    static let deviationThreshold = 1.5

    var isWithinRange: Bool {
        guard let zScore else { return true }
        return abs(zScore) < Self.deviationThreshold
    }

    /// True only when the deviation runs the concerning way.
    var isConcerning: Bool {
        guard let zScore, !isWithinRange else { return false }
        return metric.elevatedIsConcerning ? zScore > 0 : zScore < 0
    }

    var formattedValue: String {
        String(format: "%.\(metric.decimals)f", value)
    }

    var formattedBaseline: String? {
        baseline.map { String(format: "%.\(metric.decimals)f", $0) }
    }
}

// MARK: - Result

struct VitalsResult {
    let readings: [VitalReading]
    let baselineDays: Int

    var withinRangeCount: Int {
        readings.filter(\.isWithinRange).count
    }

    var concerning: [VitalReading] {
        readings.filter(\.isConcerning)
    }

    /// The pre-symptomatic pattern: elevated wrist temperature, elevated
    /// respiratory rate and elevated resting heart rate together.
    ///
    /// Any one of these alone is unremarkable — a warm room, a late meal, a
    /// glass of wine. All three moving the same way on the same night is the
    /// combination worth noticing. Deliberately phrased as an observation about
    /// the data rather than a medical claim, because that's all it is.
    var showsStrainPattern: Bool {
        let flagged = Set(concerning.map(\.metric))
        let signature: Set<VitalReading.Metric> = [
            .wristTemperature, .respiratoryRate, .restingHeartRate
        ]
        return signature.isSubset(of: flagged)
    }

    var summary: String {
        if showsStrainPattern {
            return "Wrist temperature, respiratory rate and resting heart rate are all elevated together. That combination often shows up a day or two before you feel run down."
        }
        if concerning.isEmpty {
            return "All \(readings.count) readings sit inside your normal range."
        }
        let names = concerning.map(\.metric.displayName).joined(separator: ", ")
        return "\(names) outside your usual range. Worth watching rather than worrying about."
    }
}

// MARK: - Engine

enum VitalsEngine {

    static let baselineWindowDays = 60
    static let minimumBaselineDays = 14

    static func vitals(for day: DailyMetrics, history: [DailyMetrics]) -> VitalsResult? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day.date)

        guard let windowStart = calendar.date(
            byAdding: .day, value: -baselineWindowDays, to: dayStart
        ) else { return nil }

        let baseline = history.filter {
            let d = calendar.startOfDay(for: $0.date)
            return d >= windowStart && d < dayStart
        }

        var readings: [VitalReading] = []

        func add(_ metric: VitalReading.Metric, value: Double?, samples: [Double]) {
            guard let value else { return }
            readings.append(makeReading(metric: metric, value: value, samples: samples))
        }

        add(.restingHeartRate, value: day.restingHeartRate,
            samples: baseline.compactMap(\.restingHeartRate))
        add(.hrv, value: day.hrvSDNN,
            samples: baseline.compactMap(\.hrvSDNN))
        add(.respiratoryRate, value: day.respiratoryRate,
            samples: baseline.compactMap(\.respiratoryRate))
        // HealthKit reports oxygen saturation as a fraction.
        add(.bloodOxygen, value: day.bloodOxygen.map { $0 * 100 },
            samples: baseline.compactMap { $0.bloodOxygen.map { $0 * 100 } })
        add(.wristTemperature, value: day.wristTemperatureDelta,
            samples: baseline.compactMap(\.wristTemperatureDelta))

        guard !readings.isEmpty else { return nil }
        return VitalsResult(readings: readings, baselineDays: baseline.count)
    }

    private static func makeReading(
        metric: VitalReading.Metric,
        value: Double,
        samples: [Double]
    ) -> VitalReading {
        // Not enough history to judge: show the number, claim nothing about it.
        guard samples.count >= minimumBaselineDays else {
            return VitalReading(metric: metric, value: value, baseline: nil, zScore: nil)
        }

        let mean = samples.mean
        let sd = samples.standardDeviation

        guard sd > 0.001 else {
            return VitalReading(metric: metric, value: value, baseline: mean, zScore: 0)
        }

        return VitalReading(
            metric: metric,
            value: value,
            baseline: mean,
            zScore: (value - mean) / sd
        )
    }
}
