//
//  Models.swift
//  Training load app — SwiftData model layer
//
//  Reading notes for someone coming from Java/JS:
//
//  • `@Model` is a Swift *macro*. At compile time it rewrites this class to add
//    persistence machinery — change tracking, lazy loading, the works. Think of it
//    as @Entity in JPA, except the code generation happens in the compiler rather
//    than at runtime. You never write the SQL or the schema.
//
//  • `final class` means "not subclassable." SwiftData requires classes (not structs)
//    for models because it needs reference semantics to track changes. `final` is a
//    performance win and is the default you should reach for.
//
//  • `var name: String = ""` — SwiftData wants every stored property to have either a
//    default value or to be set in init. This is what makes schema migration possible
//    later, so it's a rule worth following even when it feels redundant.
//
//  • A trailing `?` makes a type optional (`Double?` = "a Double or nothing"). Swift
//    has no implicit null — if a value can be absent, the type must say so, and the
//    compiler forces you to handle the absent case. This is the single biggest
//    day-one difference from Java.
//

import Foundation
import SwiftData

// MARK: - Supporting enums
//
// `String` after the enum name gives each case a raw string value, which is what
// lets SwiftData persist it. `Codable` is Swift's serialization protocol.
// `CaseIterable` synthesizes an `.allCases` array — handy for building pickers.

enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest
    case back
    case shoulders
    case biceps
    case triceps
    case forearms
    case quads
    case hamstrings
    case glutes
    case calves
    case core

    var id: String { rawValue }

    /// Human-readable label for UI. Computed property — no storage, runs on access.
    var displayName: String {
        switch self {
        case .chest:      return "Chest"
        case .back:       return "Back"
        case .shoulders:  return "Shoulders"
        case .biceps:     return "Biceps"
        case .triceps:    return "Triceps"
        case .forearms:   return "Forearms"
        case .quads:      return "Quads"
        case .hamstrings: return "Hamstrings"
        case .glutes:     return "Glutes"
        case .calves:     return "Calves"
        case .core:       return "Core"
        }
    }

    /// Coarse split used for upper/lower programming.
    var isUpperBody: Bool {
        switch self {
        case .chest, .back, .shoulders, .biceps, .triceps, .forearms:
            return true
        case .quads, .hamstrings, .glutes, .calves, .core:
            return false
        }
    }
}

enum Equipment: String, Codable, CaseIterable, Identifiable {
    case barbell
    case dumbbell
    case machine
    case cable
    case bodyweight
    case kettlebell
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .barbell:    return "Barbell"
        case .dumbbell:   return "Dumbbell"
        case .machine:    return "Machine"
        case .cable:      return "Cable"
        case .bodyweight: return "Bodyweight"
        case .kettlebell: return "Kettlebell"
        case .other:      return "Other"
        }
    }

    /// Smallest sensible weight jump for this equipment type, in pounds.
    /// Barbells jump 5 lb (2.5 lb plate per side); dumbbells and machines
    /// typically come in 5 lb increments too but vary by gym.
    var defaultIncrement: Double {
        switch self {
        case .barbell:    return 5.0
        case .dumbbell:   return 5.0
        case .machine:    return 10.0
        case .cable:      return 5.0
        case .kettlebell: return 8.0
        case .bodyweight: return 0.0
        case .other:      return 5.0
        }
    }
}

// MARK: - Exercise
//
// This is both the exercise definition *and* its template configuration. Picking
// "Bench Press" from the library carries its target rep range and weight increment
// along with it, which is what makes double-progression prescriptions possible.

@Model
final class Exercise {
    /// `@Attribute(.unique)` enforces a uniqueness constraint at the store level,
    /// so you can't accidentally end up with two "Bench Press" entries.
    @Attribute(.unique) var name: String = ""

    var primaryMuscle: MuscleGroup = MuscleGroup.chest
    var secondaryMuscles: [MuscleGroup] = []
    var equipment: Equipment = Equipment.barbell

    // --- Double progression configuration ---

    /// Bottom of the target rep range. Hit this at a new weight, then climb.
    var targetRepMin: Int = 8

    /// Top of the target rep range. Clear this on every working set to earn a
    /// weight increase.
    var targetRepMax: Int = 12

    /// How much to add when the rep target is cleared, in pounds.
    var weightIncrement: Double = 5.0

    /// Typical working set count. Only a UI prefill — not enforced anywhere.
    var defaultSetCount: Int = 3

    var notes: String = ""
    var createdAt: Date = Date()

    /// Inverse side of the SetEntry relationship. `.nullify` means deleting an
    /// Exercise leaves its SetEntry rows intact with a nil exercise rather than
    /// destroying training history — deleting an exercise definition should never
    /// silently erase months of logged data.
    @Relationship(deleteRule: .nullify, inverse: \SetEntry.exercise)
    var setEntries: [SetEntry] = []

    init(
        name: String,
        primaryMuscle: MuscleGroup,
        secondaryMuscles: [MuscleGroup] = [],
        equipment: Equipment = .barbell,
        targetRepMin: Int = 8,
        targetRepMax: Int = 12,
        weightIncrement: Double? = nil,
        defaultSetCount: Int = 3,
        notes: String = ""
    ) {
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.targetRepMin = targetRepMin
        self.targetRepMax = targetRepMax
        // `??` is the nil-coalescing operator: use the left side unless it's nil,
        // in which case fall back to the right. Lets the caller override the
        // equipment-derived default without having to know it.
        self.weightIncrement = weightIncrement ?? equipment.defaultIncrement
        self.defaultSetCount = defaultSetCount
        self.notes = notes
        self.createdAt = Date()
    }

    /// Every muscle this movement trains, primary first, no duplicates.
    var allMuscles: [MuscleGroup] {
        var result = [primaryMuscle]
        for muscle in secondaryMuscles where muscle != primaryMuscle {
            result.append(muscle)
        }
        return result
    }
}

// MARK: - WorkoutSession

@Model
final class WorkoutSession {
    var date: Date = Date()
    var notes: String = ""

    /// If this session lines up with a workout Apple Watch recorded, we store the
    /// HKWorkout's UUID so heart-rate data can be joined to the logged sets. Optional
    /// because plenty of lifting sessions never get recorded on the watch.
    var linkedHealthKitWorkoutID: UUID?

    /// `.cascade` here is deliberate and is the opposite choice from Exercise:
    /// deleting a session *should* delete its sets, because a set has no meaning
    /// outside the session it belongs to.
    @Relationship(deleteRule: .cascade, inverse: \SetEntry.session)
    var sets: [SetEntry] = []

    init(date: Date = Date(), notes: String = "", linkedHealthKitWorkoutID: UUID? = nil) {
        self.date = date
        self.notes = notes
        self.linkedHealthKitWorkoutID = linkedHealthKitWorkoutID
    }

    /// Working sets only — warmups are excluded from every load calculation.
    var workingSets: [SetEntry] {
        sets.filter { !$0.isWarmup }
    }

    /// Total mechanical work: Σ(weight × reps) across working sets.
    /// This is the number that makes lifting actually register as strain.
    var totalVolumeLoad: Double {
        workingSets.reduce(0) { $0 + $1.volumeLoad }
    }

    /// Volume broken out by muscle group. Because variations rotate between
    /// sessions, this is the view that shows whether a muscle is being trained
    /// enough regardless of which movement was used.
    var volumeByMuscleGroup: [MuscleGroup: Double] {
        var totals: [MuscleGroup: Double] = [:]
        for entry in workingSets {
            guard let exercise = entry.exercise else { continue }
            // Primary muscle takes full credit, secondaries take half. Crude, but
            // it's the standard convention and it beats ignoring them entirely.
            totals[exercise.primaryMuscle, default: 0] += entry.volumeLoad
            for muscle in exercise.secondaryMuscles where muscle != exercise.primaryMuscle {
                totals[muscle, default: 0] += entry.volumeLoad * 0.5
            }
        }
        return totals
    }
}

// MARK: - SetEntry

@Model
final class SetEntry {
    var weight: Double = 0
    var reps: Int = 0

    /// Rate of Perceived Exertion, 1–10, where 10 is failure. Optional because
    /// it's genuinely tedious to log every set and the app shouldn't demand it.
    /// When present it sharpens the load model considerably: 5 reps at RPE 9 is a
    /// very different stimulus from 5 at RPE 6.
    var rpe: Double?

    /// Warmups are logged for completeness but excluded from load math.
    var isWarmup: Bool = false

    var timestamp: Date = Date()

    // Both optional because SwiftData relationships are nullable by nature, and
    // because .nullify on Exercise means these can legitimately become nil.
    var exercise: Exercise?
    var session: WorkoutSession?

    init(
        weight: Double,
        reps: Int,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        exercise: Exercise? = nil,
        session: WorkoutSession? = nil,
        timestamp: Date = Date()
    ) {
        self.weight = weight
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.exercise = exercise
        self.session = session
        self.timestamp = timestamp
    }

    /// Mechanical work for this set.
    var volumeLoad: Double {
        weight * Double(reps)
    }

    /// Estimated one-rep max via the Epley formula:
    ///
    ///     e1RM = weight × (1 + reps / 30)
    ///
    /// Epley is reasonably accurate up to about 10 reps and drifts high beyond
    /// that, so sets above 12 reps return nil rather than a number that would
    /// pollute the strength-progression chart with noise.
    var estimatedOneRepMax: Double? {
        guard reps > 0, reps <= 12, weight > 0 else { return nil }
        return weight * (1.0 + Double(reps) / 30.0)
    }
}

// MARK: - DailyMetrics
//
// One row per day of HealthKit-derived biometrics plus the scores computed from
// them. Cached rather than recomputed on every view load, because the rolling
// baselines scan 60 days of samples and that is not something to do on a scroll.

@Model
final class DailyMetrics {
    @Attribute(.unique) var date: Date = Date()

    // --- Raw HealthKit inputs. All optional: any sensor can miss a night,
    // and the recovery model has to degrade gracefully when one is absent. ---

    /// Heart rate variability, SDNN in milliseconds. Apple stores SDNN
    /// specifically — not rMSSD, which is what most of the sports-science
    /// literature uses. They're correlated but not interchangeable, so baselines
    /// must be built from your own history rather than population norms.
    var hrvSDNN: Double?

    var restingHeartRate: Double?
    var respiratoryRate: Double?

    /// Wrist temperature *deviation* from your personal baseline, in °C.
    /// Series 8 and newer only. A sustained rise often precedes illness.
    var wristTemperatureDelta: Double?

    var bloodOxygen: Double?
    var vo2Max: Double?

    // --- Sleep, in minutes, from HKCategoryValueSleepAnalysis ---
    var sleepDurationMinutes: Double?
    var deepSleepMinutes: Double?
    var remSleepMinutes: Double?
    var coreSleepMinutes: Double?
    var awakeMinutes: Double?

    // --- Computed scores, filled in by the engines ---
    var recoveryScore: Double?
    var cardiovascularLoad: Double?
    var mechanicalLoad: Double?
    var totalStrain: Double?

    var lastComputed: Date?

    init(date: Date) {
        // Normalize to midnight so one calendar day maps to exactly one row and
        // the .unique constraint behaves.
        self.date = Calendar.current.startOfDay(for: date)
    }

    /// Sleep efficiency: time asleep as a fraction of time in bed.
    var sleepEfficiency: Double? {
        guard let total = sleepDurationMinutes, let awake = awakeMinutes, total > 0 else {
            return nil
        }
        return (total - awake) / total
    }
}
