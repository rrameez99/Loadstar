//
//  RecoveryEngine.swift
//  Loadstar
//
//  Turns raw biometrics into a recovery score.
//
//  The core idea: no single HRV number means anything. 60 ms is excellent for one
//  person and a warning sign for another. What carries signal is *deviation from
//  your own rolling baseline*, which is exactly a z-score:
//
//      z = (today − μ) / σ
//
//  Every component below is computed that way, then combined. Because the engine
//  reports its components alongside the total, the app can always answer "why is
//  my recovery 62 today" instead of asking you to trust a number.
//
//  Pure functions, no framework dependencies — so all of this is unit-testable
//  without a database or a device.
//

import Foundation

// MARK: - Component

/// One input to the recovery score, carried with enough context to explain itself.
struct RecoveryComponent: Identifiable {
    let id = UUID()
    let name: String
    let value: Double
    let baseline: Double
    let zScore: Double
    let contribution: Double   // 0–100 after direction and clamping
    let weight: Double
    let unit: String

    /// Whether a *higher* raw value is better. HRV yes; resting heart rate and
    /// respiratory rate no.
    let higherIsBetter: Bool

    var deviationDescription: String {
        let delta = value - baseline
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", delta)) \(unit) vs \(String(format: "%.1f", baseline)) baseline"
    }

    /// `zScore` is stored already direction-corrected — for resting heart rate,
    /// a drop below baseline is recorded as a *positive* z because it's good news.
    /// So this is simply "is the corrected z positive." Applying `higherIsBetter`
    /// again here double-flipped the sign and coloured every inverted metric
    /// backwards.
    var isFavourable: Bool {
        zScore >= 0
    }

    /// Plain-language direction of the raw value, which is what a reader expects
    /// in a sentence: resting HR 13 bpm under baseline is "below," even though
    /// that's favourable.
    var rawDirection: String {
        value >= baseline ? "above" : "below"
    }
}

// MARK: - Result

struct RecoveryResult {
    let score: Double              // 0–100
    let components: [RecoveryComponent]
    let sleepScore: Double?        // 0–100, reported separately as its own ring
    let baselineDays: Int

    /// Whoop-style banding. The thresholds are conventional rather than derived —
    /// they exist to make the number actionable, not because 67 is physiologically
    /// distinct from 66.
    enum Band: String {
        case high = "High"
        case moderate = "Moderate"
        case low = "Low"

        var guidance: String {
            switch self {
            case .high:
                return "Your body is primed. A hard session is well tolerated today."
            case .moderate:
                return "Functioning normally. Train, but this isn't the day to chase a record."
            case .low:
                return "Your baseline markers are down. Consider lighter work or a rest day."
            }
        }
    }

    var band: Band {
        switch score {
        case 67...:  return .high
        case 34..<67: return .moderate
        default:     return .low
        }
    }

    /// The component that moved the score furthest from neutral — the honest
    /// answer to "why is it this number today."
    var dominantDriver: RecoveryComponent? {
        components.max { abs($0.zScore) * $0.weight < abs($1.zScore) * $1.weight }
    }
}

// MARK: - Engine

enum RecoveryEngine {

    /// Rolling baseline window. 60 days is long enough for σ to be stable but
    /// short enough to track genuine fitness changes rather than averaging over
    /// a whole year of a changing athlete.
    static let baselineWindowDays = 60

    /// Minimum history before a score is meaningful. Below this, σ is so noisy
    /// that z-scores swing wildly and the number would be actively misleading.
    static let minimumBaselineDays = 14

    /// Component weights. HRV dominates because it's the most direct autonomic
    /// signal available from a wrist sensor; sleep is next because it's the input
    /// you can actually control.
    ///
    /// These are judgment calls informed by how the commercial systems weight
    /// theirs, not values derived from your data. They're centralized here so
    /// they can be tuned in one place once there's enough history to check them.
    static let hrvWeight = 0.40
    static let restingHRWeight = 0.25
    static let sleepWeight = 0.25
    static let respiratoryWeight = 0.10

    /// Target sleep in hours, used for the sleep-performance component.
    static let sleepNeedHours = 8.0

    // MARK: Entry point

    /// Computes recovery for `day` using the preceding history as baseline.
    ///
    /// - Parameter history: all DailyMetrics. Only days strictly *before* `day`
    ///   inside the baseline window are used, so today's own value never
    ///   contributes to the baseline it's being judged against.
    static func recovery(for day: DailyMetrics, history: [DailyMetrics]) -> RecoveryResult? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day.date)

        guard let windowStart = calendar.date(
            byAdding: .day, value: -baselineWindowDays, to: dayStart
        ) else { return nil }

        let baseline = history.filter {
            let d = calendar.startOfDay(for: $0.date)
            return d >= windowStart && d < dayStart
        }

        guard baseline.count >= minimumBaselineDays else { return nil }

        var components: [RecoveryComponent] = []

        if let component = component(
            name: "HRV",
            value: day.hrvSDNN,
            samples: baseline.compactMap(\.hrvSDNN),
            weight: hrvWeight,
            unit: "ms",
            higherIsBetter: true
        ) { components.append(component) }

        if let component = component(
            name: "Resting HR",
            value: day.restingHeartRate,
            samples: baseline.compactMap(\.restingHeartRate),
            weight: restingHRWeight,
            unit: "bpm",
            higherIsBetter: false
        ) { components.append(component) }

        if let component = component(
            name: "Respiratory rate",
            value: day.respiratoryRate,
            samples: baseline.compactMap(\.respiratoryRate),
            weight: respiratoryWeight,
            unit: "br/min",
            higherIsBetter: false
        ) { components.append(component) }

        let sleepScore = sleepPerformance(for: day)

        if let sleepScore {
            // Sleep enters as an absolute performance figure rather than a z-score:
            // consistently sleeping six hours shouldn't normalize into "fine."
            // A baseline would quietly reward you for being reliably underslept.
            components.append(
                RecoveryComponent(
                    name: "Sleep",
                    value: (day.sleepDurationMinutes ?? 0) / 60,
                    baseline: sleepNeedHours,
                    zScore: (sleepScore - 50) / 25,
                    contribution: sleepScore,
                    weight: sleepWeight,
                    unit: "h",
                    higherIsBetter: true
                )
            )
        }

        guard !components.isEmpty else { return nil }

        // Renormalize by the weights actually present, so a missing sensor
        // reweights the others rather than silently dragging the score down.
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let weighted = components.reduce(0) { $0 + $1.contribution * $1.weight }
        let score = (weighted / totalWeight).clamped(to: 0...100)

        return RecoveryResult(
            score: score,
            components: components,
            sleepScore: sleepScore,
            baselineDays: baseline.count
        )
    }

    // MARK: Components

    private static func component(
        name: String,
        value: Double?,
        samples: [Double],
        weight: Double,
        unit: String,
        higherIsBetter: Bool
    ) -> RecoveryComponent? {
        guard let value, samples.count >= minimumBaselineDays else { return nil }

        let mean = samples.mean
        let sd = samples.standardDeviation

        // A near-zero σ means the metric hasn't varied — any deviation would
        // divide into an enormous z. Treat it as neutral instead.
        guard sd > 0.001 else {
            return RecoveryComponent(
                name: name, value: value, baseline: mean, zScore: 0,
                contribution: 50, weight: weight, unit: unit,
                higherIsBetter: higherIsBetter
            )
        }

        let rawZ = (value - mean) / sd
        let directedZ = higherIsBetter ? rawZ : -rawZ

        // Map z to 0–100 with z = ±2 hitting the rails. Two standard deviations
        // covers ~95% of days, so the scale spends its resolution where the data
        // actually lives instead of on outliers.
        let contribution = (50 + 25 * directedZ).clamped(to: 0...100)

        return RecoveryComponent(
            name: name,
            value: value,
            baseline: mean,
            zScore: directedZ,
            contribution: contribution,
            weight: weight,
            unit: unit,
            higherIsBetter: higherIsBetter
        )
    }

    /// Sleep performance: time asleep against need, lightly penalized for
    /// fragmentation. Capped at 100 — sleeping ten hours doesn't bank credit.
    static func sleepPerformance(for day: DailyMetrics) -> Double? {
        guard let minutes = day.sleepDurationMinutes, minutes > 0 else { return nil }

        let hours = minutes / 60
        var performance = (hours / sleepNeedHours) * 100

        // Efficiency below 85% is genuinely disrupted sleep, so scale the score
        // by how much of the night was actually spent asleep.
        if let efficiency = day.sleepEfficiency, efficiency < 0.85 {
            performance *= (efficiency / 0.85)
        }

        return performance.clamped(to: 0...100)
    }
}

// MARK: - Small numeric helpers

extension Array where Element == Double {
    var mean: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }

    /// Sample standard deviation (n − 1). The Bessel correction matters here
    /// because these windows are small — with 20 samples, dividing by n
    /// underestimates σ by about 2.5%, which biases every z-score outward.
    var standardDeviation: Double {
        guard count > 1 else { return 0 }
        let m = mean
        let sumSquares = reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSquares / Double(count - 1)).squareRoot()
    }

    var median: Double {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        let mid = count / 2
        return count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
