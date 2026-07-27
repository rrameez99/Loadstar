//
//  ProgressionEngineTests.swift
//  LoadstarTests
//
//  Double progression, e1RM series, stall detection, and personal records.
//
//  The first test here is the one that matters most: it's the bug that shipped,
//  where logging set 1 made *today* the "last session" so set 2 was told to beat
//  set 1. That turns double progression into an ascending ramp inside a single
//  workout.
//

import Testing
import Foundation
@testable import Loadstar

@MainActor
struct ProgressionEngineTests {

    // MARK: The within-session bug

    @Test("Every set in a session gets the same target")
    func setsWithinOneSessionShareATarget() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12, increment: 5)

        // Last week: 3 × 8 at 60 kg.
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7),
                 weight: 60, reps: [8, 8, 8])

        // Today: one set logged at 9 reps.
        let today = makeSets(in: context, exercise: bench, on: TestDate.reference,
                             weight: 60, reps: [9])

        let history = fetchSets(context)
        let recommendation = ProgressionEngine.recommendation(
            for: bench,
            history: history,
            before: TestDate.reference
        )

        // Should still be aiming to beat *last week's* 8, not this morning's 9.
        #expect(recommendation.targetReps == 9)
        #expect(isClose(recommendation.targetWeight, 60))
        _ = today
    }

    @Test("Without the exclusion, the engine compares a session to itself")
    func withoutExclusionTheTargetDrifts() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7),
                 weight: 60, reps: [8, 8, 8])
        makeSets(in: context, exercise: bench, on: TestDate.reference,
                 weight: 60, reps: [9])

        // Pinning the old behaviour so the difference is visible and deliberate:
        // with no cutoff, today is the most recent session and the target climbs
        // off this morning's set rather than last week's.
        let unbounded = ProgressionEngine.recommendation(for: bench, history: fetchSets(context))
        let bounded = ProgressionEngine.recommendation(for: bench, history: fetchSets(context),
                                                       before: TestDate.reference)

        #expect(unbounded.targetReps == 10)
        #expect(bounded.targetReps == 9)
    }

    // MARK: Double progression

    @Test("Clearing the top of the range earns a weight increase")
    func clearingRangeAddsWeight() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12, increment: 5, sets: 3)

        // 3 × 12 at 60 kg — the top of the range on every working set.
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 60, reps: [12, 12, 12])

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: fetchSets(context), before: TestDate.reference
        )

        #expect(isClose(recommendation.targetWeight, 65))
        #expect(recommendation.targetReps == 8)   // back to the bottom of the range

        if case .earnedWeightIncrease = recommendation.rationale {
            // expected
        } else {
            Issue.record("Expected an earned weight increase, got \(recommendation.rationale)")
        }
    }

    @Test("Falling short of the range adds a rep instead")
    func shortOfRangeAddsReps() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12, sets: 3)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 60, reps: [10, 10, 9])

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: fetchSets(context), before: TestDate.reference
        )

        // Judged on the *weakest* working set, so 9 → 10.
        #expect(isClose(recommendation.targetWeight, 60))
        #expect(recommendation.targetReps == 10)
    }

    @Test("A back-off set doesn't drag the assessment down")
    func backOffSetsAreIgnored() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12, increment: 5, sets: 3)

        // Three sets at 60, then a lighter fourth. Without filtering to the top
        // weight, that last set would read as a regression.
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 60, reps: [12, 12, 12])
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 40, reps: [15])

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: fetchSets(context), before: TestDate.reference
        )

        #expect(isClose(recommendation.targetWeight, 65))
    }

    @Test("Warmups never influence the prescription")
    func warmupsIgnored() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12, sets: 3)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 20, reps: [10], warmup: true)
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(3),
                 weight: 60, reps: [10, 10, 10])

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: fetchSets(context), before: TestDate.reference
        )

        #expect(isClose(recommendation.targetWeight, 60))
    }

    @Test("A first-ever exercise asks for a starting weight")
    func firstTime() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 8...12)

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: [], before: TestDate.reference
        )

        #expect(recommendation.targetWeight == 0)
        #expect(recommendation.targetReps == 8)
        if case .firstTime = recommendation.rationale {
            // expected
        } else {
            Issue.record("Expected .firstTime, got \(recommendation.rationale)")
        }
    }

    @Test("The prescription inherits the unit the exercise was last logged in")
    func unitInheritedFromHistory() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context, repRange: 4...6, increment: 5)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(4),
                 weight: 135, reps: [6, 6, 6], unit: .pounds)

        let recommendation = ProgressionEngine.recommendation(
            for: bench, history: fetchSets(context), before: TestDate.reference
        )

        // The number has to match the plate in front of you, whatever the app's
        // global preference happens to be.
        #expect(recommendation.unit == .pounds)
        #expect(isClose(recommendation.targetWeight, 140))
    }

    @Test("Loadable rounding never prescribes an impossible weight")
    func roundsToLoadableWeights() {
        #expect(ProgressionEngine.roundToLoadable(62.4, increment: 5) == 60)
        #expect(ProgressionEngine.roundToLoadable(63.0, increment: 5) == 65)
        #expect(ProgressionEngine.roundToLoadable(61.0, increment: 2.5) == 60)
        // A zero increment must not divide by zero.
        #expect(ProgressionEngine.roundToLoadable(61.0, increment: 0) == 61)
    }

    // MARK: e1RM series and stalls

    @Test("The e1RM series takes the best set of each day, in order")
    func oneRepMaxSeries() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(14), weight: 60, reps: [8])
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 62.5, reps: [8, 6])
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(1), weight: 65, reps: [8])

        let series = ProgressionEngine.oneRepMaxSeries(for: bench, history: fetchSets(context))

        #expect(series.count == 3)
        #expect(series[0].date < series[1].date)      // chronological
        #expect(series[2].estimate > series[0].estimate)
        // Best set of the middle day is 62.5 × 8, not 62.5 × 6.
        #expect(isClose(series[1].estimate, 62.5 * (1 + 8.0/30), tolerance: 0.01))
    }

    @Test("No improvement across three sessions reads as a stall")
    func stallDetection() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        for week in [3, 2, 1] {
            makeSets(in: context, exercise: bench, on: TestDate.daysAgo(week * 7),
                     weight: 60, reps: [8])
        }

        #expect(ProgressionEngine.isStalled(for: bench, history: fetchSets(context)))
    }

    @Test("Steady improvement is not a stall")
    func improvementIsNotAStall() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(21), weight: 60, reps: [8])
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(14), weight: 65, reps: [8])
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 70, reps: [8])

        #expect(!ProgressionEngine.isStalled(for: bench, history: fetchSets(context)))
    }

    @Test("Too little history can't be a stall")
    func stallNeedsHistory() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 60, reps: [8])

        #expect(!ProgressionEngine.isStalled(for: bench, history: fetchSets(context)))
    }

    // MARK: Personal records

    @Test("A set cannot beat its own record")
    func setDoesNotCompeteWithItself() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 60, reps: [8])
        let newSet = makeSets(in: context, exercise: bench, on: TestDate.reference,
                              weight: 70, reps: [8])[0]

        let history = fetchSets(context)
        let records = PersonalRecordEngine.records(for: newSet, history: history)

        // Present in history, but excluded from its own comparison — otherwise
        // nothing would ever register, since every set ties itself.
        #expect(records.contains { $0.kind == .estimatedOneRepMax })
        #expect(records.contains { $0.kind == .weight })
    }

    @Test("More reps at the same weight is a record")
    func repRecordAtSameWeight() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 60, reps: [8])
        let better = makeSets(in: context, exercise: bench, on: TestDate.reference,
                              weight: 60, reps: [9])[0]

        let records = PersonalRecordEngine.records(for: better, history: fetchSets(context))

        // The case a weight-only definition would miss entirely.
        #expect(records.contains { $0.kind == .repsAtWeight })
    }

    @Test("Warmups are never records")
    func warmupsAreNotRecords() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 60, reps: [8])
        let warmup = makeSets(in: context, exercise: bench, on: TestDate.reference,
                              weight: 200, reps: [1], warmup: true)[0]

        // A warmup at an unfamiliar weight would otherwise register as a
        // heaviest-ever, which is exactly backwards.
        #expect(PersonalRecordEngine.records(for: warmup, history: fetchSets(context)).isEmpty)
    }

    @Test("A weaker set sets no records")
    func weakerSetIsNotARecord() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7), weight: 100, reps: [8])
        let weaker = makeSets(in: context, exercise: bench, on: TestDate.reference,
                              weight: 60, reps: [5])[0]

        #expect(PersonalRecordEngine.records(for: weaker, history: fetchSets(context)).isEmpty)
    }

    @Test("Records are unit-agnostic")
    func recordsCompareAcrossUnits() throws {
        let context = try makeTestContext()
        let bench = makeExercise(in: context)

        // 100 lb ≈ 45.36 kg. Then 50 kg, which is genuinely heavier.
        makeSets(in: context, exercise: bench, on: TestDate.daysAgo(7),
                 weight: 100, reps: [8], unit: .pounds)
        let heavier = makeSets(in: context, exercise: bench, on: TestDate.reference,
                               weight: 50, reps: [8], unit: .kilograms)[0]

        let records = PersonalRecordEngine.records(for: heavier, history: fetchSets(context))
        #expect(records.contains { $0.kind == .weight })
    }

    // MARK: Helper

    private func fetchSets(_ context: ModelContext) -> [SetEntry] {
        (try? context.fetch(FetchDescriptor<SetEntry>())) ?? []
    }
}
