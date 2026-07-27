//
//  StrainEngine.swift
//  Loadstar
//
//  Training load — the half that Whoop and Athlytic get wrong for lifters.
//
//  Those apps derive strain almost entirely from heart rate. That works for
//  running and cycling and badly undercounts resistance training, where heart
//  rate drops back to near-resting during the 2–3 minutes between sets. A heavy
//  squat session can register as a walk.
//
//  So load here has two independent channels:
//
//    Cardiovascular  — Banister TRIMP from workout heart rate
//    Mechanical      — volume load from logged sets, normalized to body weight
//
//  They're summed in a common unit and then compressed onto a 0–21 scale.
//

import Foundation

// MARK: - Result

struct StrainResult {
    let strain: Double              // 0–21
    let cardiovascularLoad: Double  // TRIMP units
    let mechanicalLoad: Double      // TRIMP-equivalent units
    let rawVolumeKg: Double         // for display

    var hasCardio: Bool { cardiovascularLoad > 0 }
    var hasMechanical: Bool { mechanicalLoad > 0 }

    /// Share of the day's load that came from lifting. The number that shows why
    /// this app exists: on a heavy leg day this is often 80%+, and a heart-rate
    /// only model would have reported almost nothing.
    var mechanicalShare: Double? {
        let total = cardiovascularLoad + mechanicalLoad
        guard total > 0 else { return nil }
        return mechanicalLoad / total
    }

    enum Band: String {
        case light = "Light"
        case moderate = "Moderate"
        case strenuous = "Strenuous"
        case allOut = "All Out"
    }

    var band: Band {
        switch strain {
        case ..<8:    return .light
        case 8..<14:  return .moderate
        case 14..<18: return .strenuous
        default:      return .allOut
        }
    }
}

/// A workout as far as the load model cares: how long, and how hard.
///
/// Codable so it can be persisted on DailyMetrics. Without that, the per-workout
/// heart-rate queries would have to be re-run every time a view wanted to show
/// what you actually did — dozens of HealthKit round-trips inside a view body.
struct WorkoutSummary: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let start: Date
    let duration: TimeInterval
    let averageHeartRate: Double?
    let activityName: String

    /// TRIMP for this bout alone, so a workout list can show what each one
    /// contributed rather than only the day's total.
    func trimp(restingHR: Double, maxHR: Double, coefficient: Double) -> Double {
        guard let averageHeartRate else { return 0 }
        return StrainEngine.trimp(
            durationMinutes: duration / 60,
            averageHR: averageHeartRate,
            restingHR: restingHR,
            maxHR: maxHR,
            coefficient: coefficient
        )
    }

    var durationText: String {
        let minutes = Int(duration / 60)
        return minutes >= 60
            ? "\(minutes / 60)h \(minutes % 60)m"
            : "\(minutes)m"
    }
}

// MARK: - Engine

enum StrainEngine {

    // MARK: Calibration constants
    //
    // These three numbers convert between incommensurable things — heartbeats and
    // kilograms — and set where the 0–21 scale saturates. They are *chosen*, not
    // derived: there is no published constant for "how much TRIMP is a set of
    // squats worth." They're isolated here, named, and documented so they can be
    // recalibrated against real history rather than buried in an expression.

    /// Converts body-weight-normalized volume into TRIMP-equivalent units.
    /// Set so a solid lifting session (~150× body weight in volume) lands near
    /// the TRIMP of a moderate 45-minute run.
    static let mechanicalToTrimpFactor = 0.55

    /// Load at which the strain curve reaches ~63% of maximum. Larger values
    /// stretch the scale; smaller ones saturate it sooner.
    static let strainSaturationConstant = 150.0

    /// Top of the scale, matching the Borg CR-10 × 2.1 convention that Whoop uses.
    static let maxStrain = 21.0

    // MARK: Cardiovascular load

    /// Banister TRIMP for a single bout:
    ///
    ///     TRIMP = duration(min) × HRr × 0.64 × e^(b × HRr)
    ///     HRr   = (HRavg − HRrest) / (HRmax − HRrest)
    ///
    /// The exponential is what makes this better than "minutes × average heart
    /// rate": physiological cost rises disproportionately at high intensity, so
    /// ten minutes hard is worth far more than twenty minutes easy.
    ///
    /// `b` differs by sex (1.92 male, 1.67 female) — from the original literature,
    /// reflecting measured differences in the blood-lactate response.
    static func trimp(
        durationMinutes: Double,
        averageHR: Double,
        restingHR: Double,
        maxHR: Double,
        coefficient: Double
    ) -> Double {
        guard maxHR > restingHR, durationMinutes > 0 else { return 0 }

        let reserve = (averageHR - restingHR) / (maxHR - restingHR)
        // Below resting is sensor noise, above max means the profile's max is
        // stale rather than that physiology was exceeded.
        let hrr = reserve.clamped(to: 0...1)

        return durationMinutes * hrr * 0.64 * exp(coefficient * hrr)
    }

    static func cardiovascularLoad(
        workouts: [WorkoutSummary],
        restingHR: Double,
        maxHR: Double,
        coefficient: Double
    ) -> Double {
        workouts.reduce(0) { total, workout in
            guard let avgHR = workout.averageHeartRate else { return total }
            return total + trimp(
                durationMinutes: workout.duration / 60,
                averageHR: avgHR,
                restingHR: restingHR,
                maxHR: maxHR,
                coefficient: coefficient
            )
        }
    }

    // MARK: Mechanical load

    /// Converts a day's volume load into TRIMP-equivalent units.
    ///
    /// Normalizing by body weight is what makes this comparable across people and
    /// across a bulk or cut: 10,000 kg of volume is a much larger stimulus for a
    /// 61 kg lifter than for a 100 kg one.
    static func mechanicalLoad(volumeKg: Double, bodyMassKg: Double) -> Double {
        guard volumeKg > 0, bodyMassKg > 0 else { return 0 }
        let relativeVolume = volumeKg / bodyMassKg
        return relativeVolume * mechanicalToTrimpFactor
    }

    // MARK: Combined strain

    /// Compresses total load onto 0–21 with a saturating exponential:
    ///
    ///     strain = 21 × (1 − e^(−load / k))
    ///
    /// Saturating rather than linear because the difference between an easy day
    /// and a moderate one matters far more than the difference between a very
    /// hard day and a slightly harder one. Linear scaling would waste most of the
    /// range on extremes you rarely reach.
    static func strain(
        workouts: [WorkoutSummary],
        volumeKg: Double,
        restingHR: Double,
        maxHR: Double,
        bodyMassKg: Double,
        coefficient: Double
    ) -> StrainResult {
        let cardio = cardiovascularLoad(
            workouts: workouts,
            restingHR: restingHR,
            maxHR: maxHR,
            coefficient: coefficient
        )
        let mechanical = mechanicalLoad(volumeKg: volumeKg, bodyMassKg: bodyMassKg)
        let total = cardio + mechanical

        let strain = maxStrain * (1 - exp(-total / strainSaturationConstant))

        return StrainResult(
            strain: strain.clamped(to: 0...maxStrain),
            cardiovascularLoad: cardio,
            mechanicalLoad: mechanical,
            rawVolumeKg: volumeKg
        )
    }

    // MARK: Acute:chronic workload ratio

    /// ACWR — the metric consumer apps hide and sports scientists actually use.
    ///
    ///     ACWR = mean daily load over 7 days / mean daily load over 28 days
    ///
    /// Roughly: 0.8–1.3 is the "sweet spot," and sustained values above ~1.5 are
    /// associated with elevated injury risk in the team-sport literature. The
    /// evidence is genuinely contested — it's a useful lens on whether you're
    /// ramping too fast, not a law of nature.
    static func acuteChronicRatio(dailyLoads: [(date: Date, load: Double)], asOf date: Date) -> Double? {
        let calendar = Calendar.current

        guard
            let acuteStart = calendar.date(byAdding: .day, value: -7, to: date),
            let chronicStart = calendar.date(byAdding: .day, value: -28, to: date)
        else { return nil }

        let acute = dailyLoads.filter { $0.date > acuteStart && $0.date <= date }
        let chronic = dailyLoads.filter { $0.date > chronicStart && $0.date <= date }

        // Needs a real chronic window; three days of history can't establish a
        // baseline and would produce an alarming ratio from nothing.
        guard chronic.count >= 14 else { return nil }

        // And it needs actual *training* in that window, not just calendar days.
        // Sixty days of zero-load rows technically satisfies the count check but
        // would report "0.00 — undertraining," which reads as a finding when it's
        // really an absence of data.
        let trainingDays = chronic.filter { $0.load > 0 }.count
        guard trainingDays >= 5 else { return nil }

        let acuteMean = acute.map(\.load).reduce(0, +) / 7.0
        let chronicMean = chronic.map(\.load).reduce(0, +) / 28.0

        guard chronicMean > 0 else { return nil }
        return acuteMean / chronicMean
    }

    /// Foster's training monotony: mean daily load over its standard deviation.
    /// High monotony — the same load every single day with no variation — is
    /// itself a risk factor, independent of how much total work you're doing.
    static func monotony(dailyLoads: [Double]) -> Double? {
        guard dailyLoads.count >= 7 else { return nil }
        let sd = dailyLoads.standardDeviation
        guard sd > 0.001 else { return nil }
        return dailyLoads.mean / sd
    }

    enum ACWRZone: String {
        case detraining = "Undertraining"
        case optimal = "Optimal"
        case caution = "Caution"
        case highRisk = "High risk"

        var guidance: String {
            switch self {
            case .detraining:
                return "Recent load is well below your established base. Fine if intentional."
            case .optimal:
                return "Your recent load sits in a sustainable range relative to your base."
            case .caution:
                return "You're ramping faster than your base supports. Watch for accumulating fatigue."
            case .highRisk:
                return "Recent load far exceeds your base. This is the pattern associated with injury."
            }
        }
    }

    static func zone(for ratio: Double) -> ACWRZone {
        switch ratio {
        case ..<0.8:     return .detraining
        case 0.8..<1.3:  return .optimal
        case 1.3..<1.5:  return .caution
        default:         return .highRisk
        }
    }
}
