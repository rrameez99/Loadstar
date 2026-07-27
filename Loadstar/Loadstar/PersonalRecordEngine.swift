//
//  PersonalRecordEngine.swift
//  Loadstar
//
//  Detects lifetime bests. Pure functions over a set list — no SwiftData, no
//  SwiftUI, no HealthKit — so this file drops into a watchOS target unchanged and
//  can be unit-tested without a device.
//
//  Four kinds of record, because "PR" means different things depending on how you
//  train that day. Adding a rep at the same weight is real progress and a
//  weight-only definition would miss it entirely.
//

import Foundation
import SwiftData

// MARK: - Record

struct PersonalRecord: Identifiable, Hashable {
    let id = UUID()
    let kind: Kind
    let exerciseName: String
    let value: Double
    let previous: Double?
    let date: Date

    enum Kind: String, Hashable {
        case estimatedOneRepMax
        case weight
        case repsAtWeight
        case sessionVolume

        var label: String {
            switch self {
            case .estimatedOneRepMax: return "Estimated 1RM"
            case .weight:             return "Heaviest weight"
            case .repsAtWeight:       return "Most reps at weight"
            case .sessionVolume:      return "Session volume"
            }
        }

        var symbol: String {
            switch self {
            case .estimatedOneRepMax: return "trophy.fill"
            case .weight:             return "scalemass.fill"
            case .repsAtWeight:       return "arrow.up.circle.fill"
            case .sessionVolume:      return "chart.bar.fill"
            }
        }
    }

    /// Improvement over the previous best, as a fraction. Nil on a first-ever record.
    var improvement: Double? {
        guard let previous, previous > 0 else { return nil }
        return (value - previous) / previous
    }

    var headline: String {
        switch kind {
        case .estimatedOneRepMax:
            return "New estimated 1RM — \(format(value)) kg"
        case .weight:
            return "Heaviest ever — \(format(value)) kg"
        case .repsAtWeight:
            return "\(Int(value)) reps at \(format(previous ?? 0)) kg"
        case .sessionVolume:
            return "Biggest session — \(Int(value)) kg"
        }
    }

    private func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Bests

/// A snapshot of every lifetime best for one exercise.
struct ExerciseBests {
    let estimatedOneRepMax: Double?
    let heaviestWeight: Double?
    let bestSessionVolume: Double?

    /// Highest rep count achieved at each distinct weight, so "10 reps at 60 kg"
    /// can be recognized as a record even though 60 kg isn't your heaviest.
    let repsByWeight: [Double: Int]
}

// MARK: - Engine

enum PersonalRecordEngine {

    /// Minimum improvement before something counts as a record.
    ///
    /// Without this, floating-point noise and 0.1 kg differences would fire a
    /// celebration constantly, and a notification that goes off every set stops
    /// meaning anything.
    static let minimumImprovement = 0.001

    /// Computes lifetime bests for an exercise, optionally ignoring one set.
    ///
    /// - Parameter excluding: the set being evaluated. When checking whether a
    ///   just-logged set is a record, it must not be compared against itself.
    static func bests(
        forExerciseNamed name: String,
        history: [SetEntry],
        excluding excludedID: PersistentIdentifier? = nil
    ) -> ExerciseBests {
        let relevant = history.filter {
            $0.exercise?.name == name
            && !$0.isWarmup
            && $0.reps > 0
            && $0.persistentModelID != excludedID
        }

        var repsByWeight: [Double: Int] = [:]
        for entry in relevant {
            // Rounded to 0.1 kg so 60.0 and 60.00001 aren't treated as different
            // weights, which would make every set its own trivial record.
            let key = (entry.totalWeightKg * 10).rounded() / 10
            repsByWeight[key] = max(repsByWeight[key] ?? 0, entry.reps)
        }

        // Session volume is grouped by calendar day rather than by session object,
        // matching how progression history is read elsewhere.
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.timestamp) }
        let bestVolume = byDay.values
            .map { $0.reduce(0) { $0 + $1.volumeLoad } }
            .max()

        return ExerciseBests(
            estimatedOneRepMax: relevant.compactMap(\.estimatedOneRepMax).max(),
            heaviestWeight: relevant.map(\.totalWeightKg).max(),
            bestSessionVolume: bestVolume,
            repsByWeight: repsByWeight
        )
    }

    /// Records set by a single set, checked against everything logged before it.
    ///
    /// Warmups are never records. That sounds obvious but matters: a warmup at a
    /// weight you've never used before would otherwise register as a heaviest-ever.
    static func records(for entry: SetEntry, history: [SetEntry]) -> [PersonalRecord] {
        guard !entry.isWarmup,
              entry.reps > 0,
              entry.totalWeightKg > 0,
              let name = entry.exercise?.name
        else { return [] }

        let previous = bests(
            forExerciseNamed: name,
            history: history,
            excluding: entry.persistentModelID
        )

        var found: [PersonalRecord] = []

        if let e1rm = entry.estimatedOneRepMax {
            let old = previous.estimatedOneRepMax
            if old == nil || e1rm > old! * (1 + minimumImprovement) {
                found.append(
                    PersonalRecord(
                        kind: .estimatedOneRepMax,
                        exerciseName: name,
                        value: e1rm,
                        previous: old,
                        date: entry.timestamp
                    )
                )
            }
        }

        let weight = entry.totalWeightKg
        if let old = previous.heaviestWeight {
            if weight > old * (1 + minimumImprovement) {
                found.append(
                    PersonalRecord(kind: .weight, exerciseName: name,
                                   value: weight, previous: old, date: entry.timestamp)
                )
            }
        } else {
            found.append(
                PersonalRecord(kind: .weight, exerciseName: name,
                               value: weight, previous: nil, date: entry.timestamp)
            )
        }

        // Rep record only counts when the weight isn't itself a record — otherwise
        // every first set at a new weight would fire two celebrations at once.
        let key = (weight * 10).rounded() / 10
        if let previousReps = previous.repsByWeight[key], entry.reps > previousReps {
            found.append(
                PersonalRecord(
                    kind: .repsAtWeight,
                    exerciseName: name,
                    value: Double(entry.reps),
                    previous: weight,
                    date: entry.timestamp
                )
            )
        }

        return found
    }

    /// Every lifetime best across the library, most recent first — for a PR feed.
    static func allTimeRecords(history: [SetEntry]) -> [PersonalRecord] {
        let working = history.filter { !$0.isWarmup && $0.reps > 0 }
        let names = Set(working.compactMap { $0.exercise?.name })

        return names.compactMap { name -> PersonalRecord? in
            let sets = working.filter { $0.exercise?.name == name }
            guard let best = sets.compactMap({ entry -> (SetEntry, Double)? in
                guard let e = entry.estimatedOneRepMax else { return nil }
                return (entry, e)
            }).max(by: { $0.1 < $1.1 }) else { return nil }

            return PersonalRecord(
                kind: .estimatedOneRepMax,
                exerciseName: name,
                value: best.1,
                previous: nil,
                date: best.0.timestamp
            )
        }
        .sorted { $0.date > $1.date }
    }
}
