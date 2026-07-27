//
//  StrainEngineTests.swift
//  LoadstarTests
//
//  TRIMP, mechanical load, and the acute:chronic ratio.
//
//  Every expected value here was computed by hand from the published formula
//  before the test was written. That ordering matters — deriving the expectation
//  from what the code currently returns tests nothing except that the code
//  hasn't changed.
//

import Testing
import Foundation
@testable import Loadstar

struct StrainEngineTests {

    // MARK: TRIMP

    @Test("TRIMP matches a hand-computed Banister value")
    func trimpHandComputed() {
        // 30 min at 150 bpm, resting 60, max 195, male (b = 1.92).
        //
        //   HRr   = (150 − 60) / (195 − 60) = 90/135 = 0.6667
        //   TRIMP = 30 × 0.6667 × 0.64 × e^(1.92 × 0.6667)
        //         = 30 × 0.6667 × 0.64 × e^1.28
        //         = 12.8 × 3.5966
        //         = 46.04
        let result = StrainEngine.trimp(
            durationMinutes: 30,
            averageHR: 150,
            restingHR: 60,
            maxHR: 195,
            coefficient: 1.92
        )

        #expect(isClose(result, 46.04, tolerance: 0.1))
    }

    @Test("The female coefficient produces a lower value at the same effort")
    func sexCoefficientDiffers() {
        let male = StrainEngine.trimp(durationMinutes: 30, averageHR: 150,
                                      restingHR: 60, maxHR: 195, coefficient: 1.92)
        let female = StrainEngine.trimp(durationMinutes: 30, averageHR: 150,
                                        restingHR: 60, maxHR: 195, coefficient: 1.67)

        // Straight from the literature: the smaller exponent gives a smaller
        // value for identical heart-rate reserve.
        #expect(female < male)
        #expect(isClose(female, 39.0, tolerance: 0.5))
    }

    @Test("Intensity dominates duration")
    func exponentialWeighting() {
        // The reason for the exponential rather than minutes × average HR:
        // ten minutes hard should outweigh twenty minutes easy.
        let hardShort = StrainEngine.trimp(durationMinutes: 10, averageHR: 180,
                                           restingHR: 60, maxHR: 195, coefficient: 1.92)
        let easyLong = StrainEngine.trimp(durationMinutes: 20, averageHR: 110,
                                          restingHR: 60, maxHR: 195, coefficient: 1.92)

        #expect(hardShort > easyLong)
    }

    @Test("Heart rate below resting or above max is clamped")
    func heartRateReserveClamping() {
        // Below resting is sensor noise, not negative effort.
        let belowResting = StrainEngine.trimp(durationMinutes: 30, averageHR: 45,
                                              restingHR: 60, maxHR: 195, coefficient: 1.92)
        #expect(belowResting == 0)

        // Above max means the profile's max is stale, not that physiology broke.
        let aboveMax = StrainEngine.trimp(durationMinutes: 30, averageHR: 220,
                                          restingHR: 60, maxHR: 195, coefficient: 1.92)
        let atMax = StrainEngine.trimp(durationMinutes: 30, averageHR: 195,
                                       restingHR: 60, maxHR: 195, coefficient: 1.92)
        #expect(isClose(aboveMax, atMax))
    }

    @Test("A nonsensical heart-rate reserve returns zero rather than a wild number")
    func invalidReserve() {
        let result = StrainEngine.trimp(durationMinutes: 30, averageHR: 150,
                                        restingHR: 200, maxHR: 195, coefficient: 1.92)
        #expect(result == 0)
    }

    // MARK: Mechanical load

    @Test("Mechanical load scales with volume and inversely with body mass")
    func mechanicalLoadNormalization() {
        // The same session is a bigger stimulus for a lighter lifter.
        let lightLifter = StrainEngine.mechanicalLoad(volumeKg: 10_000, bodyMassKg: 61)
        let heavyLifter = StrainEngine.mechanicalLoad(volumeKg: 10_000, bodyMassKg: 100)

        #expect(lightLifter > heavyLifter)

        // 10000/61 × 0.55 = 90.16
        #expect(isClose(lightLifter, 90.16, tolerance: 0.1))
    }

    @Test("Zero volume or missing body mass yields no load, not a divide by zero")
    func mechanicalLoadGuards() {
        #expect(StrainEngine.mechanicalLoad(volumeKg: 0, bodyMassKg: 70) == 0)
        #expect(StrainEngine.mechanicalLoad(volumeKg: 5000, bodyMassKg: 0) == 0)
    }

    // MARK: Combined strain

    @Test("Strain saturates rather than growing without bound")
    func strainSaturation() {
        let modest = StrainEngine.strain(workouts: [], volumeKg: 5_000,
                                         restingHR: 60, maxHR: 195,
                                         bodyMassKg: 70, coefficient: 1.92)
        let enormous = StrainEngine.strain(workouts: [], volumeKg: 100_000,
                                           restingHR: 60, maxHR: 195,
                                           bodyMassKg: 70, coefficient: 1.92)

        #expect(enormous.strain > modest.strain)
        #expect(enormous.strain <= StrainEngine.maxStrain)

        // Doubling the work must not double the score — that's what saturating
        // means, and it's why the scale spends its range where days actually live.
        let doubled = StrainEngine.strain(workouts: [], volumeKg: 10_000,
                                          restingHR: 60, maxHR: 195,
                                          bodyMassKg: 70, coefficient: 1.92)
        #expect(doubled.strain < modest.strain * 2)
    }

    @Test("A lifting-only day is reported as entirely mechanical")
    func liftingOnlyDayAttribution() {
        // The differentiator, asserted: no workouts recorded, so a heart-rate-only
        // model would report nothing at all.
        let result = StrainEngine.strain(workouts: [], volumeKg: 8_000,
                                         restingHR: 60, maxHR: 195,
                                         bodyMassKg: 70, coefficient: 1.92)

        #expect(result.cardiovascularLoad == 0)
        #expect(result.mechanicalLoad > 0)
        #expect(result.mechanicalShare == 1.0)
        #expect(result.strain > 0)
    }

    @Test("A rest day has no strain and no share to report")
    func emptyDay() {
        let result = StrainEngine.strain(workouts: [], volumeKg: 0,
                                         restingHR: 60, maxHR: 195,
                                         bodyMassKg: 70, coefficient: 1.92)

        #expect(result.strain == 0)
        #expect(result.mechanicalShare == nil)
    }

    // MARK: Acute:chronic ratio

    @Test("A steady load produces a ratio of 1")
    func acwrSteadyState() {
        // Identical load every day for 28 days: the 7-day mean equals the 28-day
        // mean, so the ratio is exactly 1.
        let loads = (0..<28).map {
            (date: TestDate.daysAgo($0), load: 100.0)
        }

        let ratio = StrainEngine.acuteChronicRatio(dailyLoads: loads, asOf: TestDate.reference)
        #expect(isClose(ratio ?? 0, 1.0, tolerance: 0.01))
        #expect(StrainEngine.zone(for: ratio ?? 0) == .optimal)
    }

    @Test("A sudden ramp is flagged as high risk")
    func acwrSpike() {
        // Three weeks easy, then a week at triple the load.
        var loads: [(date: Date, load: Double)] = []
        for day in 0..<7 { loads.append((TestDate.daysAgo(day), 300)) }
        for day in 7..<28 { loads.append((TestDate.daysAgo(day), 100)) }

        let ratio = StrainEngine.acuteChronicRatio(dailyLoads: loads, asOf: TestDate.reference)

        // acute = 300, chronic = (7×300 + 21×100)/28 = 150 → 2.0
        #expect(isClose(ratio ?? 0, 2.0, tolerance: 0.05))
        #expect(StrainEngine.zone(for: ratio ?? 0) == .highRisk)
    }

    @Test("Too little history returns nothing rather than a misleading number")
    func acwrRequiresHistory() {
        let sparse = (0..<5).map { (date: TestDate.daysAgo($0), load: 100.0) }
        #expect(StrainEngine.acuteChronicRatio(dailyLoads: sparse, asOf: TestDate.reference) == nil)
    }

    @Test("Calendar days without training don't count as history")
    func acwrRequiresActualTraining() {
        // This is the bug that shipped: sixty days of zero-load rows satisfied the
        // day count and produced "0.00 — undertraining", which reads as a finding
        // when it's an absence of data.
        let empty = (0..<28).map { (date: TestDate.daysAgo($0), load: 0.0) }
        #expect(StrainEngine.acuteChronicRatio(dailyLoads: empty, asOf: TestDate.reference) == nil)

        // Four training days still isn't enough to establish a base.
        var barelyAny = (0..<28).map { (date: TestDate.daysAgo($0), load: 0.0) }
        for day in 0..<4 { barelyAny[day] = (TestDate.daysAgo(day), 200) }
        #expect(StrainEngine.acuteChronicRatio(dailyLoads: barelyAny, asOf: TestDate.reference) == nil)
    }

    @Test("ACWR zones sit at the documented boundaries")
    func acwrZoneBoundaries() {
        #expect(StrainEngine.zone(for: 0.5) == .detraining)
        #expect(StrainEngine.zone(for: 0.8) == .optimal)
        #expect(StrainEngine.zone(for: 1.29) == .optimal)
        #expect(StrainEngine.zone(for: 1.3) == .caution)
        #expect(StrainEngine.zone(for: 1.5) == .highRisk)
    }

    // MARK: Monotony

    @Test("Identical daily loads read as maximally monotonous")
    func monotonyOfAFlatWeek() {
        // Zero variation means an undefined ratio, not an infinite one.
        let flat = Array(repeating: 100.0, count: 7)
        #expect(StrainEngine.monotony(dailyLoads: flat) == nil)

        // Mean 100, sd 47.6 → about 2.1
        let varied = [50.0, 150, 100, 30, 170, 90, 110]
        let result = StrainEngine.monotony(dailyLoads: varied)
        #expect(result != nil)
        #expect(isClose(result ?? 0, 2.1, tolerance: 0.2))
    }
}
