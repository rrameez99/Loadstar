//
//  RecoveryEngineTests.swift
//  LoadstarTests
//
//  Z-scores, direction handling, and graceful degradation.
//
//  The direction tests exist because this shipped wrong once. `isFavourable`
//  applied the higher-is-better flip a second time to an already-corrected
//  z-score, so resting heart rate and respiratory rate were coloured backwards
//  in the UI — a low resting HR, which is good news, showed orange.
//

import Testing
import Foundation
import SwiftData
@testable import Loadstar

@MainActor
struct RecoveryEngineTests {

    // MARK: Statistics

    @Test("Mean and standard deviation match hand calculation")
    func basicStatistics() {
        let sample = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

        #expect(isClose(sample.mean, 5.0))
        // Sample standard deviation (n − 1), not population (n).
        // Population would give 2.0; Bessel's correction gives 2.138.
        #expect(isClose(sample.standardDeviation, 2.138, tolerance: 0.01))
    }

    @Test("Standard deviation of a single value is zero, not a crash")
    func standardDeviationEdgeCases() {
        #expect([1.0].standardDeviation == 0)
        #expect([Double]().standardDeviation == 0)
        #expect([Double]().mean == 0)
    }

    @Test("Median handles even and odd counts")
    func median() {
        #expect([1.0, 2.0, 3.0].median == 2.0)
        #expect([1.0, 2.0, 3.0, 4.0].median == 2.5)
        // Unsorted input must still work — the caller shouldn't have to know.
        #expect([3.0, 1.0, 2.0].median == 2.0)
    }

    // MARK: Baseline requirements

    @Test("Below the minimum history, no score is produced")
    func insufficientBaseline() throws {
        let context = try makeTestContext()

        // Ten days, when fourteen are required. σ over ten samples is too noisy
        // for a z-score to mean anything, and a confident wrong number is worse
        // than an honest gap.
        var history: [DailyMetrics] = []
        for day in 1...10 {
            history.append(makeDailyMetrics(in: context, date: TestDate.daysAgo(day),
                                            hrv: 60, restingHR: 55, sleepMinutes: 480))
        }
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 65, restingHR: 54, sleepMinutes: 480)

        #expect(RecoveryEngine.recovery(for: today, history: history + [today]) == nil)
    }

    @Test("Today's own value never contributes to its own baseline")
    func todayExcludedFromBaseline() throws {
        let context = try makeTestContext()

        // Thirty days at exactly 60 ms, then a wild outlier today.
        var history: [DailyMetrics] = []
        for day in 1...30 {
            history.append(makeDailyMetrics(in: context, date: TestDate.daysAgo(day),
                                            hrv: 60, restingHR: 55, sleepMinutes: 480))
        }
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 200, restingHR: 55, sleepMinutes: 480)

        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))
        let hrv = try #require(result.components.first { $0.name == "HRV" })

        // If today leaked into the baseline, the mean would be pulled above 60.
        #expect(isClose(hrv.baseline, 60, tolerance: 0.5))
    }

    // MARK: Direction

    @Test("A high HRV scores well; higher is better")
    func hrvDirection() throws {
        let context = try makeTestContext()
        let history = makeVariedHistory(in: context, hrvValues: hrvSpread)

        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 80, restingHR: 55, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))
        let hrv = try #require(result.components.first { $0.name == "HRV" })

        #expect(hrv.zScore > 0)
        #expect(hrv.isFavourable)
        #expect(hrv.contribution > 50)
    }

    @Test("A low resting heart rate scores well; lower is better")
    func restingHeartRateDirectionIsInverted() throws {
        let context = try makeTestContext()
        let history = makeVariedHistory(in: context, hrvValues: hrvSpread)

        // Baseline resting HR sits around 55. A drop to 48 is good news.
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 60, restingHR: 48, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))
        let rhr = try #require(result.components.first { $0.name == "Resting HR" })

        // The direction-corrected z is positive even though the raw value fell.
        #expect(rhr.zScore > 0)
        #expect(rhr.isFavourable)          // this is the assertion that was wrong in the app
        #expect(rhr.contribution > 50)
        // The human-readable direction still describes the raw movement.
        #expect(rhr.rawDirection == "below")
    }

    @Test("An elevated resting heart rate is unfavourable")
    func elevatedRestingHeartRate() throws {
        let context = try makeTestContext()
        let history = makeVariedHistory(in: context, hrvValues: hrvSpread)

        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 60, restingHR: 66, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))
        let rhr = try #require(result.components.first { $0.name == "Resting HR" })

        #expect(rhr.zScore < 0)
        #expect(!rhr.isFavourable)
        #expect(rhr.rawDirection == "above")
    }

    // MARK: Score construction

    @Test("Contributions are clamped to 0–100 at two standard deviations")
    func contributionClamping() throws {
        let context = try makeTestContext()
        let history = makeVariedHistory(in: context, hrvValues: hrvSpread)

        // Far beyond +2σ.
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 500, restingHR: 55, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))
        let hrv = try #require(result.components.first { $0.name == "HRV" })

        #expect(hrv.contribution == 100)
        #expect(result.score <= 100)
    }

    @Test("A missing sensor reweights the others rather than scoring zero")
    func missingSensorDegradesGracefully() throws {
        let context = try makeTestContext()

        var history: [DailyMetrics] = []
        for day in 1...30 {
            history.append(makeDailyMetrics(in: context, date: TestDate.daysAgo(day),
                                            hrv: Double(55 + day % 10),
                                            restingHR: Double(52 + day % 6),
                                            respiratoryRate: 14,
                                            sleepMinutes: 480))
        }

        // No respiratory rate today.
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 62, restingHR: 53, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))

        #expect(!result.components.contains { $0.name == "Respiratory rate" })
        // Crucially: still a full-range score, not one dragged down by the gap.
        #expect(result.score > 0)
        #expect(result.score <= 100)
    }

    @Test("The dominant driver is the largest weighted deviation")
    func dominantDriver() throws {
        let context = try makeTestContext()
        let history = makeVariedHistory(in: context, hrvValues: hrvSpread)

        // HRV far off baseline, everything else on it.
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 90, restingHR: 55, sleepMinutes: 480)
        let result = try #require(RecoveryEngine.recovery(for: today, history: history + [today]))

        #expect(result.dominantDriver?.name == "HRV")
    }

    // MARK: Sleep

    @Test("Sleep is scored against a target, not against your own average")
    func sleepUsesAbsoluteTarget() throws {
        let context = try makeTestContext()

        // Six hours every night for a month. A z-score would call this "normal";
        // an absolute target correctly calls it short. Otherwise the app quietly
        // rewards you for being reliably underslept.
        var history: [DailyMetrics] = []
        for day in 1...30 {
            history.append(makeDailyMetrics(in: context, date: TestDate.daysAgo(day),
                                            hrv: Double(55 + day % 10),
                                            restingHR: 55, sleepMinutes: 360))
        }
        let today = makeDailyMetrics(in: context, date: TestDate.reference,
                                     hrv: 60, restingHR: 55, sleepMinutes: 360)

        let score = try #require(RecoveryEngine.sleepPerformance(for: today))
        // 6 hours against an 8-hour need is 75%.
        #expect(isClose(score, 75, tolerance: 0.5))
    }

    @Test("Sleep performance caps at 100")
    func sleepDoesNotBankCredit() throws {
        let context = try makeTestContext()
        let today = makeDailyMetrics(in: context, date: TestDate.reference, sleepMinutes: 720)
        #expect(RecoveryEngine.sleepPerformance(for: today) == 100)
    }

    @Test("Poor efficiency scales the sleep score down")
    func fragmentedSleepIsPenalised() throws {
        let context = try makeTestContext()

        // Eight hours in bed but 100 minutes awake: 79% efficiency, below the
        // 85% threshold, so the score is scaled rather than rewarded in full.
        let broken = makeDailyMetrics(in: context, date: TestDate.reference,
                                      sleepMinutes: 480, awakeMinutes: 100)
        let clean = makeDailyMetrics(in: context, date: TestDate.daysAgo(1),
                                     sleepMinutes: 480, awakeMinutes: 20)

        let brokenScore = try #require(RecoveryEngine.sleepPerformance(for: broken))
        let cleanScore = try #require(RecoveryEngine.sleepPerformance(for: clean))

        #expect(brokenScore < cleanScore)
    }

    @Test("No sleep data yields no sleep score")
    func missingSleep() throws {
        let context = try makeTestContext()
        let today = makeDailyMetrics(in: context, date: TestDate.reference)
        #expect(RecoveryEngine.sleepPerformance(for: today) == nil)
    }

    // MARK: Bands

    @Test("Recovery bands sit at the documented thresholds")
    func bands() {
        func band(_ score: Double) -> RecoveryResult.Band {
            RecoveryResult(score: score, components: [], sleepScore: nil, baselineDays: 60).band
        }

        #expect(band(20) == .low)
        #expect(band(33.9) == .low)
        #expect(band(34) == .moderate)
        #expect(band(66.9) == .moderate)
        #expect(band(67) == .high)
        #expect(band(95) == .high)
    }

    // MARK: Helpers

    /// A spread of HRV values rather than a constant, so σ is non-zero and
    /// z-scores are meaningful. A constant history would make every deviation
    /// divide by ~0.
    private var hrvSpread: [Double] {
        (1...30).map { 55 + Double($0 % 11) }
    }

    private func makeVariedHistory(in context: ModelContext, hrvValues: [Double]) -> [DailyMetrics] {
        hrvValues.enumerated().map { index, hrv in
            makeDailyMetrics(
                in: context,
                date: TestDate.daysAgo(index + 1),
                hrv: hrv,
                restingHR: 52 + Double(index % 7),
                respiratoryRate: 13 + Double(index % 3),
                sleepMinutes: 450 + Double(index % 5) * 10
            )
        }
    }
}
