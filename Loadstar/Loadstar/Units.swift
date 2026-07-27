//
//  Units.swift
//  Loadstar
//
//  The unit rules, in one place.
//
//  There are exactly three layers and they never blur into each other:
//
//    1. ENTRY      — you type a number and pick lb or kg. Stored verbatim,
//                    alongside its unit. Nothing is converted on the way in, so
//                    what you logged is always what you see when you look back.
//
//    2. CANONICAL  — every calculation reads SetEntry.totalWeightKg, which folds
//                    unit, per-side loading and bar weight into one kilogram
//                    figure. Kilograms purely because a single canonical unit is
//                    required and it doesn't matter which; nothing user-facing
//                    depends on the choice.
//
//    3. DISPLAY    — derived numbers (volume, e1RM, chart axes) get converted
//                    back into whichever unit you prefer, at render time.
//
//  The point of layer 2 is that a training history spanning a US gym in pounds
//  and a European gym in kilograms is still one comparable series. The point of
//  layers 1 and 3 is that you never see a number you didn't choose to see.
//

import Foundation
import SwiftUI

// MARK: - Editing canonical values in display units

extension Binding where Value == Double {
    /// Presents a stored kilogram value in the user's preferred unit, converting
    /// back on write.
    ///
    /// Bar weight is the case this exists for. It's stored canonically in
    /// kilograms like everything else, but a US lifter looking at a 45 lb bar
    /// should type `45`, not `20.4`.
    func inDisplayUnit() -> Binding<Double> {
        Binding<Double>(
            get: { DisplayUnit.value(wrappedValue) },
            set: { wrappedValue = $0 * DisplayUnit.current.toKilograms }
        )
    }
}

// MARK: - Conversion

extension WeightUnit {
    /// Kilograms → this unit.
    var fromKilograms: Double { 1 / toKilograms }

    func convert(kilograms: Double) -> Double {
        kilograms * fromKilograms
    }

    /// Smallest plate increment normally available, in this unit. US gyms run on
    /// 2.5 lb plates (5 lb per bar), metric gyms on 1.25 kg (2.5 kg per bar).
    var typicalIncrement: Double {
        switch self {
        case .pounds:    return 5
        case .kilograms: return 2.5
        }
    }
}

// MARK: - Display

/// Formats canonical kilogram values in whatever unit the user prefers.
///
/// Everything here takes kilograms and returns a string. That signature is the
/// safeguard: a function that accepted "a weight" without saying which unit is
/// exactly how conversion bugs get in.
enum DisplayUnit {

    static var current: WeightUnit {
        PreferredUnitDefaults.current
    }

    static var symbol: String {
        current.displayName
    }

    /// A single weight — "135 lb", "62.5 kg".
    static func weight(_ kilograms: Double, unit: WeightUnit? = nil) -> String {
        let target = unit ?? current
        return "\(number(target.convert(kilograms: kilograms))) \(target.displayName)"
    }

    /// Total volume. Rounded to whole units and thousands-separated, because
    /// session volumes run into five figures and "12473 lb" is unreadable.
    static func volume(_ kilograms: Double, unit: WeightUnit? = nil) -> String {
        let target = unit ?? current
        let converted = target.convert(kilograms: kilograms)
        return "\(grouped(converted)) \(target.displayName)"
    }

    /// Bare number, no unit — for chart axis labels where the unit is in the
    /// axis title instead.
    static func value(_ kilograms: Double, unit: WeightUnit? = nil) -> Double {
        (unit ?? current).convert(kilograms: kilograms)
    }

    // MARK: Formatting

    /// Drops a trailing ".0" so whole numbers read as "135" rather than "135.0",
    /// but keeps one decimal where it carries information ("62.5").
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }
}

// MARK: - Preference

/// The unit new sets default to when there's no prior session to inherit from.
///
/// Deliberately a preference and never a conversion: changing it affects what
/// gets entered next and never rewrites anything already logged. A session
/// recorded in kilograms stays recorded in kilograms.
enum PreferredUnitDefaults {
    static var current: WeightUnit {
        let raw = UserDefaults.standard.string(forKey: ProfileKey.preferredUnit)
        // Pounds by default: US gyms, US plates.
        return WeightUnit(rawValue: raw ?? "") ?? .pounds
    }
}
