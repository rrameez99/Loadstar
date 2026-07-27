//
//  ProgressionEngine.swift
//  Double-progression logic — decides what you should lift next.
//
//  This is deliberately a plain enum with static methods and no stored state, so
//  every function here is a pure input → output transformation. That matters for
//  two reasons: it's trivially unit-testable (no database, no SwiftUI, no mocking),
//  and it means the prescription logic can never disagree with itself depending on
//  what's cached.
//
//  A note on `enum` as a namespace: Swift has no static-only class idiom the way
//  Java does. An enum with no cases can't be instantiated, which makes it the
//  conventional way to group related functions without allowing `ProgressionEngine()`.
//

import Foundation

// MARK: - Recommendation types

/// What the app tells you to do on your next set of a given exercise.
struct ProgressionRecommendation {
    let exercise: Exercise
    let targetWeight: Double
    let targetReps: Int
    let setCount: Int
    let rationale: Rationale

    /// Unit the prescription is expressed in — carried through from the last
    /// session so the number matches what's written on the machine.
    let unit: WeightUnit

    /// Whether `targetWeight` is per side.
    let isPerSide: Bool

    var displayWeight: String {
        let number = targetWeight == targetWeight.rounded()
            ? String(Int(targetWeight))
            : String(format: "%.1f", targetWeight)
        return "\(number) \(unit.displayName)\(isPerSide ? " each" : "")"
    }

    /// Why this recommendation was made. Surfacing this is the whole point —
    /// the app should never hand you a number without saying where it came from.
    enum Rationale {
        /// No history for this exercise. The user picks a starting weight.
        case firstTime

        /// Every working set cleared the top of the rep range, so the weight goes up
        /// and reps reset to the bottom.
        case earnedWeightIncrease(previousWeight: Double)

        /// Still climbing within the rep range at the current weight.
        case addReps(currentBest: Int, target: Int)

        /// Last session fell short of the previous one. Repeat rather than push.
        case repeatWeight(reason: String)

        var summary: String {
            switch self {
            case .firstTime:
                return "First time logging this — pick a weight you can control."
            case .earnedWeightIncrease(let previous):
                return "Cleared the rep target at \(Self.format(previous)). Weight goes up."
            case .addReps(let current, let target):
                return "At \(current) reps, working toward \(target) before adding weight."
            case .repeatWeight(let reason):
                return reason
            }
        }

        private static func format(_ value: Double) -> String {
            // Drop the decimal when the weight is a whole number: "135" not "135.0".
            value == value.rounded()
                ? String(Int(value))
                : String(format: "%.1f", value)
        }
    }
}

/// A summary of the last time an exercise was performed.
struct ExerciseSnapshot {
    let date: Date
    let workingSets: [SetEntry]

    /// The heaviest working set, chosen by normalized kilograms so the comparison
    /// survives a gym that logs in different units.
    let topSet: SetEntry

    let bestEstimatedOneRepMax: Double?
    let totalVolume: Double

    /// Raw display weight of the top set — the number as written, not normalized.
    var topWeight: Double { topSet.weight }
}

// MARK: - Engine

enum ProgressionEngine {

    // MARK: Recommendation

    /// Computes the next prescription for an exercise using double progression:
    /// climb the rep range at a fixed weight, and when every working set clears the
    /// top of the range, add weight and drop back to the bottom.
    ///
    /// - Parameters:
    ///   - exercise: The movement being programmed.
    ///   - history: All sets ever logged for it. Order doesn't matter; this sorts.
    ///   - before: the session currently being logged, excluded from its own
    ///     comparison so every set in it gets the same target.
    static func recommendation(
        for exercise: Exercise,
        history: [SetEntry],
        before: Date? = nil
    ) -> ProgressionRecommendation {

        guard let last = lastSession(for: exercise, history: history, before: before) else {
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: 0,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .firstTime,
                unit: exercise.defaultUnit,
                isPerSide: exercise.defaultIsPerSide
            )
        }

        let unit = last.topSet.unit
        let isPerSide = last.topSet.isPerSide

        // Only sets at the heaviest weight used last session count toward
        // progression. If you did 3×8 at 135 and then a back-off set at 95, the
        // back-off set shouldn't drag the assessment down. Compared in normalized
        // kilograms so a unit change mid-history doesn't split the group.
        let topKg = last.topSet.totalWeightKg
        let topSets = last.workingSets.filter { abs($0.totalWeightKg - topKg) < 0.001 }

        guard !topSets.isEmpty else {
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: last.topWeight,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .repeatWeight(reason: "Couldn't read last session cleanly — repeating."),
                unit: unit,
                isPerSide: isPerSide
            )
        }

        let minRepsAcrossTopSets = topSets.map(\.reps).min() ?? 0
        let clearedRepTarget = minRepsAcrossTopSets >= exercise.targetRepMax
        let hitEnoughSets = topSets.count >= exercise.defaultSetCount

        // Bodyweight movements have no increment to add. Without this check they'd
        // "earn" an increase of zero and get reset to the bottom of the rep range —
        // sent backwards for succeeding. They progress on reps alone, so the range
        // ceiling doesn't apply to them.
        let canAddWeight = exercise.weightIncrement > 0

        if clearedRepTarget && hitEnoughSets && canAddWeight {
            // Earned the increase. Round to something loadable on a real barbell.
            let raw = last.topWeight + exercise.weightIncrement
            let next = roundToLoadable(raw, increment: exercise.weightIncrement)
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: next,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .earnedWeightIncrease(previousWeight: last.topWeight),
                unit: unit,
                isPerSide: isPerSide
            )
        }

        // Otherwise stay at this weight and try for one more rep than last time.
        // The rep ceiling only exists because clearing it earns weight; with no
        // weight to add, reps climb indefinitely.
        let repCeiling = canAddWeight ? exercise.targetRepMax : Int.max
        let nextRepTarget = min(minRepsAcrossTopSets + 1, repCeiling)
        return ProgressionRecommendation(
            exercise: exercise,
            targetWeight: last.topWeight,
            targetReps: nextRepTarget,
            setCount: exercise.defaultSetCount,
            rationale: .addReps(currentBest: minRepsAcrossTopSets, target: exercise.targetRepMax),
            unit: unit,
            isPerSide: isPerSide
        )
    }

    // MARK: History

    /// The most recent session in which this exercise was performed.
    ///
    /// - Parameter before: excludes this day and everything after it.
    ///
    ///   This parameter is load-bearing. Without it, logging set 1 of today's
    ///   session makes *today* the most recent session, so set 2 gets told to
    ///   beat set 1 and set 3 to beat set 2. That's an ascending ramp inside one
    ///   workout, not double progression. Progression compares sessions to each
    ///   other, so the session being logged has to be excluded from its own
    ///   comparison.
    static func lastSession(
        for exercise: Exercise,
        history: [SetEntry],
        before: Date? = nil
    ) -> ExerciseSnapshot? {
        let calendar = Calendar.current
        var relevant = history.filter { $0.exercise?.name == exercise.name && !$0.isWarmup }

        if let before {
            let cutoff = calendar.startOfDay(for: before)
            relevant = relevant.filter { calendar.startOfDay(for: $0.timestamp) < cutoff }
        }

        guard !relevant.isEmpty else { return nil }

        // Group by calendar day rather than by session object, so sets logged across
        // a split session still read as one workout.
        let byDay = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.timestamp) }

        guard let mostRecentDay = byDay.keys.max(),
              let sets = byDay[mostRecentDay],
              let topSet = sets.max(by: { $0.totalWeightKg < $1.totalWeightKg })
        else { return nil }

        return ExerciseSnapshot(
            date: mostRecentDay,
            workingSets: sets,
            topSet: topSet,
            bestEstimatedOneRepMax: sets.compactMap(\.estimatedOneRepMax).max(),
            totalVolume: sets.reduce(0) { $0 + $1.volumeLoad }
        )
    }

    /// Best estimated 1RM per day, for the strength-progression chart.
    ///
    /// e1RM rather than raw top weight, because it's comparable across rep ranges:
    /// 5 reps at 185 and 10 at 155 are nearly the same strength level, but a
    /// top-weight chart would show that as a big drop.
    static func oneRepMaxSeries(
        for exercise: Exercise,
        history: [SetEntry]
    ) -> [(date: Date, estimate: Double)] {
        let relevant = history.filter { $0.exercise?.name == exercise.name && !$0.isWarmup }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.timestamp) }

        return byDay.compactMap { day, sets -> (Date, Double)? in
            guard let best = sets.compactMap(\.estimatedOneRepMax).max() else { return nil }
            return (day, best)
        }
        .sorted { $0.0 < $1.0 }
        .map { (date: $0.0, estimate: $0.1) }
    }

    /// Detects a stall: no improvement in e1RM across the last `sessionCount`
    /// sessions. Worth surfacing, because the standard response is to deload
    /// rather than keep grinding the same weight.
    static func isStalled(
        for exercise: Exercise,
        history: [SetEntry],
        sessionCount: Int = 3
    ) -> Bool {
        let series = oneRepMaxSeries(for: exercise, history: history)
        guard series.count >= sessionCount else { return false }

        let recent = series.suffix(sessionCount).map(\.estimate)
        guard let best = recent.max(), let first = recent.first else { return false }

        // Stalled if the best of the recent window is no better than where the
        // window started, allowing a 1% tolerance for day-to-day noise.
        return best <= first * 1.01
    }

    // MARK: Helpers

    /// Rounds a weight to something you can actually load.
    ///
    /// Barbell math: plates come in pairs, so a barbell loaded in 2.5 lb plates
    /// moves in 5 lb steps. Rounding to the increment keeps the app from ever
    /// prescribing 137.5 lb on a bar that can't make it.
    static func roundToLoadable(_ weight: Double, increment: Double) -> Double {
        guard increment > 0 else { return weight }
        return (weight / increment).rounded() * increment
    }
}

// MARK: - Seed data
//
// Derived from an actual Apple Notes training log spanning April–July 2026 rather
// than a generic template, so rep ranges reflect how each movement is really
// trained: squats and presses live at 5–7, machine and isolation work at 10–12,
// forearms well above that.
//
// Defaults are kilograms and, where relevant, per-side — matching the current gym.
// Both are per-exercise, so a gym change never requires a data migration.

extension Exercise {
    static func seedLibrary() -> [Exercise] {
        [
            // --- Chest ---
            Exercise(name: "Chest Press (Machine)", primaryMuscle: .chest,
                     secondaryMuscles: [.triceps, .shoulders], equipment: .machine,
                     targetRepMin: 5, targetRepMax: 8),
            Exercise(name: "Incline Chest Press (Machine)", primaryMuscle: .chest,
                     secondaryMuscles: [.shoulders, .triceps], equipment: .machine,
                     targetRepMin: 5, targetRepMax: 8),
            // Dumbbells are inherently per side: the logged number is one bell,
            // and both hands are working.
            Exercise(name: "Incline Dumbbell Press", primaryMuscle: .chest,
                     secondaryMuscles: [.shoulders, .triceps], equipment: .dumbbell,
                     targetRepMin: 8, targetRepMax: 12, defaultIsPerSide: true),
            // One of only three movements historically logged per side.
            Exercise(name: "Bench Press (Barbell)", primaryMuscle: .chest,
                     secondaryMuscles: [.triceps, .shoulders], equipment: .barbell,
                     targetRepMin: 4, targetRepMax: 6, defaultIsPerSide: true),
            Exercise(name: "Pec Deck", primaryMuscle: .chest,
                     equipment: .machine, targetRepMin: 8, targetRepMax: 12),

            // --- Back ---
            // Three distinct machines that all got written down as "row back."
            Exercise(name: "Chest-Supported Row", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .machine,
                     targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Seated Row", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .machine,
                     targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Lat Pulldown", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .cable,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Lat Pulldown (Single Arm)", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .cable,
                     targetRepMin: 8, targetRepMax: 12),

            // --- Shoulders ---
            Exercise(name: "Shoulder Press (Dumbbell)", primaryMuscle: .shoulders,
                     secondaryMuscles: [.triceps], equipment: .dumbbell,
                     targetRepMin: 8, targetRepMax: 12, defaultIsPerSide: true),
            Exercise(name: "Shoulder Press (Machine)", primaryMuscle: .shoulders,
                     secondaryMuscles: [.triceps], equipment: .machine,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Lateral Raise (Dumbbell)", primaryMuscle: .shoulders,
                     equipment: .dumbbell, targetRepMin: 10, targetRepMax: 12,
                     defaultIsPerSide: true),
            Exercise(name: "Lateral Raise (Cable)", primaryMuscle: .shoulders,
                     equipment: .cable, targetRepMin: 8, targetRepMax: 12),

            // --- Arms ---
            Exercise(name: "Hammer Curl", primaryMuscle: .biceps,
                     secondaryMuscles: [.forearms], equipment: .cable,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Preacher Curl", primaryMuscle: .biceps,
                     equipment: .machine, targetRepMin: 8, targetRepMax: 12),
            // "Preacher curls rod 5kgs each" — an EZ-curl bar, roughly 7.5 kg empty.
            Exercise(name: "Barbell Curl", primaryMuscle: .biceps,
                     equipment: .barbell, targetRepMin: 8, targetRepMax: 12,
                     defaultIsPerSide: true, defaultBarWeightKg: 7.5),
            Exercise(name: "Overhead Triceps Extension", primaryMuscle: .triceps,
                     equipment: .cable, targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Triceps Extension", primaryMuscle: .triceps,
                     equipment: .cable, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Wrist Curl", primaryMuscle: .forearms,
                     equipment: .barbell, targetRepMin: 15, targetRepMax: 20),
            Exercise(name: "Reverse Wrist Curl", primaryMuscle: .forearms,
                     equipment: .barbell, targetRepMin: 10, targetRepMax: 15),

            // --- Legs ---
            // Squat and RDL are the other two logged per side, on a 20 kg bar.
            Exercise(name: "Squat", primaryMuscle: .quads,
                     secondaryMuscles: [.glutes, .hamstrings], equipment: .barbell,
                     targetRepMin: 5, targetRepMax: 7, defaultIsPerSide: true),
            Exercise(name: "Romanian Deadlift", primaryMuscle: .hamstrings,
                     secondaryMuscles: [.glutes, .back], equipment: .barbell,
                     targetRepMin: 5, targetRepMax: 7, defaultIsPerSide: true),
            Exercise(name: "Leg Press", primaryMuscle: .quads,
                     secondaryMuscles: [.glutes], equipment: .machine,
                     targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Hack Squat", primaryMuscle: .quads,
                     secondaryMuscles: [.glutes], equipment: .machine,
                     targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Leg Extension", primaryMuscle: .quads,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Hamstring Curl (Seated)", primaryMuscle: .hamstrings,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Hamstring Curl (Lying)", primaryMuscle: .hamstrings,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Hip Adduction", primaryMuscle: .adductors,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Hip Abduction", primaryMuscle: .glutes,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Standing Calf Raise", primaryMuscle: .calves,
                     equipment: .machine, targetRepMin: 12, targetRepMax: 15),
            Exercise(name: "Seated Calf Raise", primaryMuscle: .calves,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),
            Exercise(name: "Tibialis Raise", primaryMuscle: .tibialis,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 12),

            // --- Core ---
            Exercise(name: "Hanging Knee Raise", primaryMuscle: .core,
                     equipment: .bodyweight, targetRepMin: 6, targetRepMax: 12),
        ]
    }
}
