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
    case adductors
    case calves
    case tibialis
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
        case .adductors:  return "Adductors"
        case .calves:     return "Calves"
        case .tibialis:   return "Tibialis"
        case .core:       return "Core"
        }
    }

    /// Coarse split used for upper/lower programming.
    var isUpperBody: Bool {
        switch self {
        case .chest, .back, .shoulders, .biceps, .triceps, .forearms:
            return true
        case .quads, .hamstrings, .glutes, .adductors, .calves, .tibialis, .core:
            return false
        }
    }
}

/// Weight units. Non-negotiable for this app: the training log spans gyms in the US
/// and Denmark, so the same exercise legitimately appears in pounds one week and
/// kilograms the next. Storing a bare number would make every cross-gym comparison
/// silently wrong — 42.5 lb to 22.5 kg reads as a 47% drop and is actually a 17% gain.
enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case pounds = "lb"
    case kilograms = "kg"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Canonical storage is kilograms. Everything comparable is computed from this.
    var toKilograms: Double {
        switch self {
        case .kilograms: return 1.0
        case .pounds:    return 0.45359237
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

    /// Weight of the empty implement in kilograms. Only barbells carry one; a
    /// machine's stack number already includes everything being lifted.
    var defaultBarWeightKg: Double {
        switch self {
        case .barbell: return 20.0   // standard Olympic bar
        default:       return 0.0
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

    /// Unit this movement is usually logged in, used to prefill the entry field.
    /// Per-exercise rather than global, so a gym move doesn't require editing
    /// every entry by hand.
    var defaultUnit: WeightUnit = WeightUnit.kilograms

    /// Whether this movement is normally recorded per side — true for dumbbells
    /// and plate-loaded machines.
    var defaultIsPerSide: Bool = false

    /// Bar weight in kilograms used to prefill new sets. 20 kg for an Olympic
    /// barbell, ~7.5 kg for an EZ-curl bar, 0 for machines and dumbbells.
    var defaultBarWeightKg: Double = 0

    /// Rest between sets, in seconds. Per-exercise because the right answer varies
    /// enormously: heavy compounds need 2–3 minutes for the nervous system to
    /// recover, isolation work is fine at 60–90 seconds.
    var restSeconds: Int = 120

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
        defaultUnit: WeightUnit = .kilograms,
        defaultIsPerSide: Bool = false,
        defaultBarWeightKg: Double? = nil,
        restSeconds: Int? = nil,
        notes: String = ""
    ) {
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.targetRepMin = targetRepMin
        self.targetRepMax = targetRepMax
        self.defaultUnit = defaultUnit
        self.defaultIsPerSide = defaultIsPerSide
        self.defaultBarWeightKg = defaultBarWeightKg ?? equipment.defaultBarWeightKg
        // Derived from the rep range when unspecified: low reps means heavy work
        // means longer rest.
        self.restSeconds = restSeconds ?? (targetRepMax <= 8 ? 180 : targetRepMax <= 12 ? 120 : 75)
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

    /// Exercises intended for this session, in order — the plan, as opposed to
    /// `sets`, which is what actually happened.
    ///
    /// Stored as names rather than relationships deliberately: a plan is a list of
    /// intentions, and it shouldn't break or cascade if an exercise is later
    /// renamed or deleted from the library.
    var plannedExerciseNames: [String] = []

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
    /// The number as written in the log — 22.5, not its kilogram equivalent. Always
    /// interpret alongside `unit` and `isPerSide`.
    var weight: Double = 0
    var reps: Int = 0

    /// Unit this set was recorded in. Stored per set rather than as a global
    /// preference, because a single training history can legitimately span both.
    var unit: WeightUnit = WeightUnit.pounds

    /// True when `weight` describes one side rather than the total — two 20 lb
    /// dumbbells, or a leg press loaded with 70 lb per side. Without this, every
    /// dumbbell movement gets counted at half its real volume.
    var isPerSide: Bool = false

    /// Weight of the empty bar in kilograms, added on top of the plates.
    ///
    /// A standard Olympic bar is 20 kg, an EZ-curl bar around 7.5 kg, and machines
    /// are zero. This matters enormously at the low end: 25 kg of plates per side
    /// on a 20 kg bar is 70 kg total, not 25 — a nearly 3× error that would make
    /// every squat number meaningless.
    ///
    /// Stored per set rather than read from the Exercise, so that changing an
    /// exercise's bar later doesn't silently rewrite months of history.
    var barWeightKg: Double = 0

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
        unit: WeightUnit = .pounds,
        isPerSide: Bool = false,
        barWeightKg: Double = 0,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        exercise: Exercise? = nil,
        session: WorkoutSession? = nil,
        timestamp: Date = Date()
    ) {
        self.weight = weight
        self.reps = reps
        self.unit = unit
        self.isPerSide = isPerSide
        self.barWeightKg = barWeightKg
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.exercise = exercise
        self.session = session
        self.timestamp = timestamp
    }

    /// Total load actually moved, normalized to kilograms.
    ///
    ///     total = (weight × unit) × (per side ? 2 : 1) + bar
    ///
    /// This is the only weight figure that should ever feed a calculation or a
    /// chart. `weight` alone is a display value and is meaningless without its unit.
    var totalWeightKg: Double {
        let plates = weight * unit.toKilograms
        return (isPerSide ? plates * 2 : plates) + barWeightKg
    }

    /// Mechanical work for this set, in kilogram-reps.
    var volumeLoad: Double {
        totalWeightKg * Double(reps)
    }

    /// Estimated one-rep max in kilograms, via the Epley formula:
    ///
    ///     e1RM = weight × (1 + reps / 30)
    ///
    /// Epley is reasonably accurate up to about 10 reps and drifts high beyond
    /// that, so sets above 12 reps return nil rather than a number that would
    /// pollute the strength-progression chart with noise.
    var estimatedOneRepMax: Double? {
        guard reps > 0, reps <= 12, totalWeightKg > 0 else { return nil }
        return totalWeightKg * (1.0 + Double(reps) / 30.0)
    }

    /// The set as it would be written in a log: "22.5 kg × 6" or "20 lb each × 10".
    var displayDescription: String {
        let number = weight == weight.rounded()
            ? String(Int(weight))
            : String(format: "%.1f", weight)
        let side = isPerSide ? " each" : ""
        return "\(number) \(unit.displayName)\(side) × \(reps)"
    }

    /// Expanded form showing what the total actually works out to, for verifying
    /// that per-side and bar weight are set correctly: "25 kg each + 20 kg bar = 70 kg".
    var loadBreakdown: String {
        guard isPerSide || barWeightKg > 0 else { return "" }

        var parts: [String] = []
        let plates = weight * unit.toKilograms
        if isPerSide {
            parts.append("\(fmt(plates)) × 2")
        } else {
            parts.append("\(fmt(plates))")
        }
        if barWeightKg > 0 {
            parts.append("+ \(fmt(barWeightKg)) kg bar")
        }
        return parts.joined(separator: " ") + " = \(fmt(totalWeightKg)) kg"
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Sleep staging

enum SleepStage: String, Codable, CaseIterable, Identifiable {
    case awake
    case rem
    case core
    case deep
    case unspecified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .awake:       return "Awake"
        case .rem:         return "REM"
        case .core:        return "Light"
        case .deep:        return "Deep"
        case .unspecified: return "Asleep"
        }
    }

    /// Draw order, top to bottom — the conventional hypnogram layout puts wakefulness
    /// at the top and descends through progressively deeper stages.
    var depthRank: Int {
        switch self {
        case .awake:       return 0
        case .rem:         return 1
        case .core:        return 2
        case .deep:        return 3
        case .unspecified: return 2
        }
    }

    /// Typical share of total sleep, as a reference band rather than a target.
    /// Individual variation is wide and a single night says almost nothing —
    /// these exist so a number has context, not so it can be chased.
    var typicalRange: ClosedRange<Double>? {
        switch self {
        case .deep:  return 0.13...0.23
        case .rem:   return 0.20...0.25
        case .core:  return 0.45...0.55
        case .awake: return 0.00...0.10
        case .unspecified: return nil
        }
    }

    var countsAsAsleep: Bool {
        self != .awake
    }
}

/// One contiguous stretch of a single sleep stage.
///
/// Stored as a Codable value on DailyMetrics rather than as its own @Model: these
/// are never queried independently, only ever read as a set belonging to one
/// night, so a relationship would add join cost for no benefit.
struct SleepStageSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var stage: SleepStage
    var start: Date
    var end: Date

    var durationMinutes: Double {
        end.timeIntervalSince(start) / 60
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

    /// The night's stage-by-stage timeline, for the hypnogram. Totals alone can't
    /// show *when* deep sleep happened, which is most of what makes the chart
    /// worth looking at — deep sleep front-loads in a normal night, and a night
    /// where it doesn't looks very different at the same total.
    var sleepSegments: [SleepStageSegment] = []

    /// When the night began and ended, for labelling the timeline axis.
    var sleepStart: Date?
    var sleepEnd: Date?

    /// Workouts the watch recorded that day, kept so the app can show what you
    /// actually did rather than only the total load it produced.
    var recordedWorkouts: [WorkoutSummary] = []

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
