//
//  NumericFields.swift
//  Loadstar
//
//  Text fields for numbers that behave the way you'd expect.
//
//  SwiftUI's `TextField(value:format:)` renders a stored 0 as the literal text
//  "0", so the placeholder never shows and you have to delete a character before
//  typing. That's a small thing that happens on every single set, which makes it
//  not a small thing.
//
//  The fix is to back the field with a String and treat empty as zero, so the
//  field starts blank, shows its placeholder, and accepts typing immediately.
//

import SwiftUI

// MARK: - Decimal

struct DecimalField: View {
    let placeholder: String
    @Binding var value: Double
    var width: CGFloat = 70

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($isFocused)
            .onAppear { syncFromValue() }
            // Only pull from the model when the field isn't being edited —
            // otherwise reformatting mid-keystroke fights the cursor.
            .onChange(of: value) { _, _ in
                if !isFocused { syncFromValue() }
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                // Accept a comma decimal separator: the keypad shows whichever
                // the device locale uses, and a European keyboard gives "22,5".
                let normalized = newText.replacingOccurrences(of: ",", with: ".")
                value = Double(normalized) ?? 0
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { syncFromValue() }
            }
    }

    private func syncFromValue() {
        // Empty rather than "0" — this is the whole point.
        guard value != 0 else {
            text = ""
            return
        }
        text = value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - Integer

struct IntegerField: View {
    let placeholder: String
    @Binding var value: Int
    var width: CGFloat = 70

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($isFocused)
            .onAppear { syncFromValue() }
            .onChange(of: value) { _, _ in
                if !isFocused { syncFromValue() }
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                value = Int(newText.filter(\.isNumber)) ?? 0
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { syncFromValue() }
            }
    }

    private func syncFromValue() {
        text = value == 0 ? "" : String(value)
    }
}
