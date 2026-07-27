//
//  LoadstarTests.swift
//  LoadstarTests
//
//  The suite is split by engine:
//
//    UnitNormalizationTests  — totalWeightKg, conversion, Epley
//    StrainEngineTests       — TRIMP, mechanical load, ACWR, monotony
//    RecoveryEngineTests     — z-scores, direction handling, sleep scoring
//    ProgressionEngineTests  — double progression, e1RM series, records
//
//  Every expected value was computed by hand from the underlying formula before
//  the test was written. Deriving expectations from what the code currently
//  returns would only assert that the code hasn't changed, which is a much
//  weaker claim than that it's correct.
//

import Testing
import Foundation
@testable import Loadstar

@MainActor
struct LoadstarTests {

    /// A guard on the seed library, which is easy to break with a careless edit
    /// and whose breakage only shows up on a fresh install.
    @Test("The seed library is internally consistent")
    func seedLibraryIsValid() {
        let library = Exercise.seedLibrary()

        #expect(!library.isEmpty)

        // Unique names — Exercise.name carries a uniqueness constraint, so a
        // duplicate here would crash on first launch rather than fail politely.
        let names = library.map(\.name)
        #expect(Set(names).count == names.count)

        for exercise in library {
            #expect(exercise.targetRepMin <= exercise.targetRepMax,
                    "\(exercise.name) has an inverted rep range")
            // Bodyweight movements legitimately have no increment — there's no
            // external load to add. Everything else must have one, or double
            // progression can never advance.
            if exercise.equipment == .bodyweight {
                #expect(exercise.weightIncrement == 0,
                        "\(exercise.name) is bodyweight but has a weight increment")
            } else {
                #expect(exercise.weightIncrement > 0,
                        "\(exercise.name) has no weight increment")
            }
            #expect(exercise.restSeconds > 0,
                    "\(exercise.name) has no rest period")
            // A muscle counted as both primary and secondary is double-counted
            // in every volume calculation.
            #expect(!exercise.secondaryMuscles.contains(exercise.primaryMuscle),
                    "\(exercise.name) lists its primary muscle as secondary")
        }
    }

    @Test("Only barbell movements carry a bar weight")
    func barWeightsAreOnlyOnBarbells() {
        for exercise in Exercise.seedLibrary() where exercise.defaultBarWeightKg > 0 {
            #expect(exercise.equipment == .barbell,
                    "\(exercise.name) has a bar weight but isn't a barbell movement")
        }
    }

    @Test("Clamping behaves at and beyond the bounds")
    func clamping() {
        #expect(5.0.clamped(to: 0...10) == 5)
        #expect((-3.0).clamped(to: 0...10) == 0)
        #expect(15.0.clamped(to: 0...10) == 10)
        #expect(0.0.clamped(to: 0...10) == 0)
        #expect(10.0.clamped(to: 0...10) == 10)
    }
}
