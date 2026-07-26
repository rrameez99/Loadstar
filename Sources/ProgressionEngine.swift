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
                return "Cleared the rep target at \(Self.format(previous)) lb. Weight goes up."
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
    let topWeight: Double
    let bestEstimatedOneRepMax: Double?
    let totalVolume: Double
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
    static func recommendation(
        for exercise: Exercise,
        history: [SetEntry]
    ) -> ProgressionRecommendation {

        guard let last = lastSession(for: exercise, history: history) else {
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: 0,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .firstTime
            )
        }

        // Only sets at the heaviest weight used last session count toward
        // progression. If you did 3×8 at 135 and then a back-off set at 95, the
        // back-off set shouldn't drag the assessment down.
        let topSets = last.workingSets.filter { $0.weight == last.topWeight }

        guard !topSets.isEmpty else {
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: last.topWeight,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .repeatWeight(reason: "Couldn't read last session cleanly — repeating.")
            )
        }

        let minRepsAcrossTopSets = topSets.map(\.reps).min() ?? 0
        let clearedRepTarget = minRepsAcrossTopSets >= exercise.targetRepMax
        let hitEnoughSets = topSets.count >= exercise.defaultSetCount

        if clearedRepTarget && hitEnoughSets {
            // Earned the increase. Round to something loadable on a real barbell.
            let raw = last.topWeight + exercise.weightIncrement
            let next = roundToLoadable(raw, increment: exercise.weightIncrement)
            return ProgressionRecommendation(
                exercise: exercise,
                targetWeight: next,
                targetReps: exercise.targetRepMin,
                setCount: exercise.defaultSetCount,
                rationale: .earnedWeightIncrease(previousWeight: last.topWeight)
            )
        }

        // Otherwise stay at this weight and try for one more rep than last time.
        let nextRepTarget = min(minRepsAcrossTopSets + 1, exercise.targetRepMax)
        return ProgressionRecommendation(
            exercise: exercise,
            targetWeight: last.topWeight,
            targetReps: nextRepTarget,
            setCount: exercise.defaultSetCount,
            rationale: .addReps(currentBest: minRepsAcrossTopSets, target: exercise.targetRepMax)
        )
    }

    // MARK: History

    /// The most recent session in which this exercise was performed.
    static func lastSession(for exercise: Exercise, history: [SetEntry]) -> ExerciseSnapshot? {
        let relevant = history.filter { $0.exercise?.name == exercise.name && !$0.isWarmup }
        guard !relevant.isEmpty else { return nil }

        // Group by calendar day rather than by session object, so sets logged across
        // a split session still read as one workout.
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.timestamp) }

        guard let mostRecentDay = byDay.keys.max(),
              let sets = byDay[mostRecentDay],
              let topWeight = sets.map(\.weight).max()
        else { return nil }

        return ExerciseSnapshot(
            date: mostRecentDay,
            workingSets: sets,
            topWeight: topWeight,
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
// A starter library so the first run isn't an empty screen demanding thirty
// manual entries. Skewed toward compound movements on an upper/lower split, with
// rep ranges set the conventional way: lower ranges for heavy compounds where the
// limiting factor is force production, higher for isolation work.

extension Exercise {
    static func seedLibrary() -> [Exercise] {
        [
            // --- Upper: push ---
            Exercise(name: "Bench Press", primaryMuscle: .chest,
                     secondaryMuscles: [.triceps, .shoulders], equipment: .barbell,
                     targetRepMin: 5, targetRepMax: 8),
            Exercise(name: "Incline Dumbbell Press", primaryMuscle: .chest,
                     secondaryMuscles: [.shoulders, .triceps], equipment: .dumbbell,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Overhead Press", primaryMuscle: .shoulders,
                     secondaryMuscles: [.triceps], equipment: .barbell,
                     targetRepMin: 5, targetRepMax: 8),
            Exercise(name: "Lateral Raise", primaryMuscle: .shoulders,
                     equipment: .dumbbell, targetRepMin: 12, targetRepMax: 20),
            Exercise(name: "Triceps Pushdown", primaryMuscle: .triceps,
                     equipment: .cable, targetRepMin: 10, targetRepMax: 15),

            // --- Upper: pull ---
            // The two back movements that rotate between sessions.
            Exercise(name: "Lat Pulldown", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .cable,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Barbell Row", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .barbell,
                     targetRepMin: 6, targetRepMax: 10),
            Exercise(name: "Seated Cable Row", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .cable,
                     targetRepMin: 8, targetRepMax: 12),
            Exercise(name: "Pull-Up", primaryMuscle: .back,
                     secondaryMuscles: [.biceps], equipment: .bodyweight,
                     targetRepMin: 5, targetRepMax: 12),
            Exercise(name: "Barbell Curl", primaryMuscle: .biceps,
                     equipment: .barbell, targetRepMin: 8, targetRepMax: 12),

            // --- Lower ---
            Exercise(name: "Back Squat", primaryMuscle: .quads,
                     secondaryMuscles: [.glutes, .hamstrings], equipment: .barbell,
                     targetRepMin: 5, targetRepMax: 8),
            Exercise(name: "Romanian Deadlift", primaryMuscle: .hamstrings,
                     secondaryMuscles: [.glutes, .back], equipment: .barbell,
                     targetRepMin: 6, targetRepMax: 10),
            Exercise(name: "Deadlift", primaryMuscle: .back,
                     secondaryMuscles: [.hamstrings, .glutes], equipment: .barbell,
                     targetRepMin: 3, targetRepMax: 6),
            Exercise(name: "Leg Press", primaryMuscle: .quads,
                     secondaryMuscles: [.glutes], equipment: .machine,
                     targetRepMin: 10, targetRepMax: 15),
            Exercise(name: "Leg Curl", primaryMuscle: .hamstrings,
                     equipment: .machine, targetRepMin: 10, targetRepMax: 15),
            Exercise(name: "Calf Raise", primaryMuscle: .calves,
                     equipment: .machine, targetRepMin: 12, targetRepMax: 20),

            // --- Core ---
            Exercise(name: "Hanging Leg Raise", primaryMuscle: .core,
                     equipment: .bodyweight, targetRepMin: 8, targetRepMax: 15),
            Exercise(name: "Cable Crunch", primaryMuscle: .core,
                     equipment: .cable, targetRepMin: 10, targetRepMax: 15),
        ]
    }
}
