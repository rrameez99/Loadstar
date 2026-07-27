//
//  TestSupport.swift
//  LoadstarTests
//
//  Builders for making test data readable.
//
//  Tests are only worth having if a failure tells you what broke. That means the
//  setup has to be legible at a glance — `sets(on: monday, weight: 135, reps: [8, 8, 8])`
//  rather than six lines of object construction. Anything unreadable here shows
//  up as a test nobody trusts, which is worse than no test at all.
//

import Foundation
import SwiftData
@testable import Loadstar

// MARK: - Dates

enum TestDate {
    /// A fixed reference point, so tests never depend on when they're run.
    /// A test that passes on Tuesday and fails on Wednesday is a liability.
    static let reference = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15

    static func daysAgo(_ days: Int, from base: Date = reference) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: base)!
    }
}

// MARK: - Model container
//
// SwiftData models can't be constructed meaningfully without a container, and
// relationships (SetEntry.exercise) don't resolve outside one. In-memory means
// each test starts clean and nothing touches the disk.

@MainActor
func makeTestContext() throws -> ModelContext {
    let schema = Schema([Exercise.self, WorkoutSession.self, SetEntry.self, DailyMetrics.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

// MARK: - Builders

@MainActor
func makeExercise(
    in context: ModelContext,
    name: String = "Bench Press",
    primaryMuscle: MuscleGroup = .chest,
    secondaryMuscles: [MuscleGroup] = [],
    equipment: Equipment = .barbell,
    repRange: ClosedRange<Int> = 8...12,
    increment: Double = 5,
    sets: Int = 3,
    unit: WeightUnit = .kilograms,
    perSide: Bool = false,
    barKg: Double = 0
) -> Exercise {
    let exercise = Exercise(
        name: name,
        primaryMuscle: primaryMuscle,
        secondaryMuscles: secondaryMuscles,
        equipment: equipment,
        targetRepMin: repRange.lowerBound,
        targetRepMax: repRange.upperBound,
        weightIncrement: increment,
        defaultSetCount: sets,
        defaultUnit: unit,
        defaultIsPerSide: perSide,
        defaultBarWeightKg: barKg
    )
    context.insert(exercise)
    return exercise
}

/// Several sets of one exercise on one day.
@MainActor
@discardableResult
func makeSets(
    in context: ModelContext,
    exercise: Exercise,
    on day: Date,
    weight: Double,
    reps: [Int],
    unit: WeightUnit = .kilograms,
    perSide: Bool = false,
    barKg: Double = 0,
    warmup: Bool = false
) -> [SetEntry] {
    reps.enumerated().map { index, repCount in
        let entry = SetEntry(
            weight: weight,
            reps: repCount,
            unit: unit,
            isPerSide: perSide,
            barWeightKg: barKg,
            isWarmup: warmup,
            exercise: exercise,
            // Spaced a few minutes apart so ordering within a day is deterministic.
            timestamp: day.addingTimeInterval(Double(index) * 300)
        )
        context.insert(entry)
        return entry
    }
}

@MainActor
func makeDailyMetrics(
    in context: ModelContext,
    date: Date,
    hrv: Double? = nil,
    restingHR: Double? = nil,
    respiratoryRate: Double? = nil,
    sleepMinutes: Double? = nil,
    awakeMinutes: Double? = nil
) -> DailyMetrics {
    let row = DailyMetrics(date: date)
    row.hrvSDNN = hrv
    row.restingHeartRate = restingHR
    row.respiratoryRate = respiratoryRate
    row.sleepDurationMinutes = sleepMinutes
    row.awakeMinutes = awakeMinutes
    context.insert(row)
    return row
}

// MARK: - Tolerance

/// Floating-point comparison. `0.1 + 0.2 != 0.3` in binary floating point, so
/// every numeric assertion below needs a tolerance rather than exact equality.
func isClose(_ a: Double, _ b: Double, tolerance: Double = 0.01) -> Bool {
    abs(a - b) <= tolerance
}
