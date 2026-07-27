//
//  VitalsCard.swift
//  Loadstar
//
//  Overnight vitals and the watch's own workouts — the two things the app was
//  already collecting and never showing.
//

import SwiftUI

// MARK: - Vitals

struct VitalsCard: View {
    let result: VitalsResult
    let vo2Max: Double?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vitals")
                    .font(.headline)
                Spacer()
                Text("\(result.withinRangeCount)/\(result.readings.count) in range")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(result.concerning.isEmpty ? .green : .orange)
            }

            Text(result.summary)
                .font(.callout)
                .foregroundStyle(result.showsStrainPattern ? .orange : .secondary)

            if isExpanded {
                Divider()
                ForEach(result.readings) { reading in
                    VitalRow(reading: reading)
                }

                // VO2 max updates every few weeks rather than nightly, so it
                // isn't baselined alongside the others — it's a fitness level,
                // not a daily signal.
                if let vo2Max {
                    CardioFitnessRow(vo2Max: vo2Max)
                }

                Text("Compared against your own \(result.baselineDays)-day range, flagged beyond 1.5 standard deviations. These are observations about your data, not medical advice.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            Button(isExpanded ? "Hide readings" : "Show readings") {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            }
            .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct VitalRow: View {
    let reading: VitalReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reading.metric.symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)

            Text(reading.metric.displayName)
                .font(.callout)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(reading.formattedValue) \(reading.metric.unit)")
                    .font(.callout.monospacedDigit())

                if let baseline = reading.formattedBaseline {
                    Text("usual \(baseline)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    // Honest about not knowing yet, rather than implying normality.
                    Text("building baseline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        guard reading.zScore != nil else { return .secondary }
        if reading.isConcerning { return .orange }
        return reading.isWithinRange ? .green : .yellow
    }
}

// MARK: - Watch workouts

struct RecordedWorkoutsCard: View {
    let workouts: [WorkoutSummary]
    let restingHR: Double
    let maxHR: Double
    let coefficient: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From your watch")
                .font(.headline)

            ForEach(workouts) { workout in
                HStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(workout.activityName)
                            .font(.callout)
                        Text("\(workout.durationText) · \(workout.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        if let hr = workout.averageHeartRate {
                            Text("\(Int(hr)) bpm")
                                .font(.callout.monospacedDigit())
                        }
                        // The per-workout contribution, so the day's total is
                        // traceable back to what produced it.
                        Text("TRIMP \(Int(workout.trimp(restingHR: restingHR, maxHR: maxHR, coefficient: coefficient)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Fitness

/// VO2 max, which HealthKit updates every few weeks rather than daily.
struct CardioFitnessRow: View {
    let vo2Max: Double

    var body: some View {
        HStack {
            Label("Cardio fitness", systemImage: "lungs")
                .font(.callout)
            Spacer()
            Text("\(String(format: "%.1f", vo2Max)) ml/kg·min")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
