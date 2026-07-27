//
//  UnitNormalizationTests.swift
//  LoadstarTests
//
//  The unit layer, which everything else depends on.
//
//  If totalWeightKg is wrong, every volume, every e1RM, every strain figure and
//  every personal record is wrong with it — silently, and in a way that looks
//  plausible. These are the most important tests in the project.
//

import Testing
import Foundation
@testable import Loadstar

@MainActor
struct UnitNormalizationTests {

    // MARK: Conversion

    @Test("One pound is 0.45359237 kilograms")
    func poundConversionFactor() {
        #expect(isClose(WeightUnit.pounds.toKilograms, 0.45359237, tolerance: 0.0000001))
        #expect(WeightUnit.kilograms.toKilograms == 1.0)
    }

    @Test("100 lb and 45.359 kg are the same weight")
    func equivalentWeightsAcrossUnits() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        let inPounds = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                                weight: 100, reps: [10], unit: .pounds)[0]
        let inKilos = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                               weight: 45.359237, reps: [10], unit: .kilograms)[0]

        #expect(isClose(inPounds.totalWeightKg, inKilos.totalWeightKg))
        // The whole point: a mixed history is still one comparable series.
        #expect(isClose(inPounds.volumeLoad, inKilos.volumeLoad))
    }

    // MARK: Per-side and bar weight

    @Test("Per-side loading doubles the plates")
    func perSideDoubles() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 20, reps: [5], unit: .kilograms, perSide: true)[0]

        #expect(isClose(entry.totalWeightKg, 40))
    }

    @Test("Bar weight is added after doubling, not before")
    func barWeightAddedOnce() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        // 25 kg per side on a 20 kg bar = 70 kg, not 90.
        // Adding the bar before doubling would give 90, which is the classic
        // way to get this wrong.
        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 25, reps: [6], unit: .kilograms,
                             perSide: true, barKg: 20)[0]

        #expect(isClose(entry.totalWeightKg, 70))
        #expect(isClose(entry.volumeLoad, 420))  // 70 × 6
    }

    @Test("A US bar in pounds resolves correctly")
    func poundsPerSideWithBar() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        // 45 lb per side on a 45 lb (20.41 kg) bar = 135 lb = 61.23 kg.
        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 45, reps: [5], unit: .pounds,
                             perSide: true, barKg: 45 * 0.45359237)[0]

        #expect(isClose(entry.totalWeightKg, 135 * 0.45359237, tolerance: 0.001))
    }

    // MARK: Display

    @Test("Display converts back into the entered unit")
    func displayRoundTrip() {
        let kilograms = 61.23
        let asPounds = WeightUnit.pounds.convert(kilograms: kilograms)
        #expect(isClose(asPounds, 135, tolerance: 0.1))

        // Round trip must land where it started.
        let backToKg = asPounds * WeightUnit.pounds.toKilograms
        #expect(isClose(backToKg, kilograms))
    }

    @Test("Whole numbers format without a trailing decimal")
    func numberFormatting() {
        #expect(DisplayUnit.number(135.0) == "135")
        #expect(DisplayUnit.number(62.5) == "62.5")
        // Rounds to one decimal rather than printing float noise.
        #expect(DisplayUnit.number(61.2349) == "61.2")
    }

    // MARK: Epley

    @Test("Epley matches the published formula")
    func epleyEstimate() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        // 100 kg × 5 → 100 × (1 + 5/30) = 116.67
        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 100, reps: [5], unit: .kilograms)[0]

        #expect(isClose(entry.estimatedOneRepMax ?? 0, 116.667, tolerance: 0.01))
    }

    @Test("A single rep estimates as itself, near enough")
    func epleyAtOneRep() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        // Epley gives weight × (1 + 1/30) at one rep, so it overshoots slightly
        // by construction. Worth pinning so nobody "fixes" it later.
        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 100, reps: [1], unit: .kilograms)[0]

        #expect(isClose(entry.estimatedOneRepMax ?? 0, 103.33, tolerance: 0.01))
    }

    @Test("Above 12 reps, no estimate is offered")
    func epleyRefusesHighReps() throws {
        let context = try makeTestContext()
        let exercise = makeExercise(in: context)

        // Epley drifts high on long sets, and a bad estimate feeding a
        // progression chart is worse than a gap in it.
        let entry = makeSets(in: context, exercise: exercise, on: TestDate.reference,
                             weight: 40, reps: [20], unit: .kilograms)[0]

        #expect(entry.estimatedOneRepMax == nil)
    }
}
