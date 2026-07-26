# Training Load & Recovery App — Project Plan

**Working title:** TBD (candidates: *Ledger*, *Basis*, *Forge*, *Loadout*)
**Owner:** Rameez Rahaman
**Started:** July 2026

---

## The problem

Apple Watch Ultra 3 collects nearly every biometric a Whoop band does — HRV, resting
heart rate, respiratory rate, wrist temperature, SpO2, sleep staging, continuous HR —
but Apple's Health app presents it as a pile of disconnected charts. There is no
readiness number, no training-load model, no "should I train hard today."

Third-party apps (Athlytic, Bevel, Training Today, Gentler Streak) fill part of this
gap, but they share two weaknesses:

1. **They undercount lifting.** Strain is computed almost entirely from heart rate.
   A heavy squat session with long rest periods barely registers, because HR stays
   low between sets. For anyone whose training is primarily resistance work, the
   strain number is close to meaningless.
2. **They are black boxes.** You get a score from 0–100 with no visibility into
   which inputs moved it or how much.

Meanwhile my own lifting log lives in Apple Notes as manually typed text, completely
disconnected from any of the biometric data.

## The thesis

Build a training-load and recovery engine that:

- **Fuses mechanical load with cardiovascular load** into a single strain number, so
  lifting actually counts
- **Shows its work** — every score is expandable into the inputs and weights that
  produced it
- **Exposes real sports-science metrics** that consumer apps hide, especially the
  acute:chronic workload ratio
- **Replaces the Apple Notes lifting log** with something faster than typing

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Views (SwiftUI)                                │
│  Today · Log · Trends · Exercise Detail · Why?  │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Engines (pure Swift, unit-testable)            │
│  RecoveryEngine · StrainEngine · LoadEngine     │
└──────────┬───────────────────────┬──────────────┘
           │                       │
┌──────────▼──────────┐  ┌─────────▼──────────────┐
│  HealthKitService   │  │  SwiftData store       │
│  (biometrics in)    │  │  (my logged sets)      │
└─────────────────────┘  └────────────────────────┘
```

Keeping the engines as pure Swift with no framework dependencies is deliberate: it
makes them unit-testable, which is what lets us verify the math is actually correct
rather than merely plausible.

---

## Data model (SwiftData)

| Model | Key fields |
|---|---|
| `Exercise` | name, primary/secondary muscle groups, equipment, target rep range, progression increment |
| `WorkoutSession` | date, notes, optional linked HKWorkout UUID |
| `SetEntry` | exercise, weight, reps, RPE, isWarmup, timestamp |
| `DailyMetrics` | date, HRV, RHR, respiratory rate, wrist temp Δ, SpO2, sleep stages, computed scores |

Note: **HealthKit has no native schema for sets/reps/weight.** The strength log is
entirely our own data model. This is extra work but it's also the part that makes the
app differentiated rather than a reskin of Apple Health.

### Logging model: exercise-level templates

`Exercise` doubles as the template. Each one carries its own configuration — target rep
range, weight increment, default set count — so picking "Bench Press" from the library
prefills last session's numbers and you only adjust what changed. New exercises are
added to the library as they're tried; nothing is pre-imposed.

Day-level templates ("Push Day A") are deliberately *not* in v1. Training is a 4×/week
upper/lower split with variations rotating between sessions (lat pulldowns one day,
horizontal rows the next), so rigid day templates would fight the rotation. If grouping
proves useful later it can be layered on top as an optional collection of exercises.

### Double progression

The training pattern is: add reps until the top of the target range, then add weight and
reset to the bottom. This is *double progression*, and because `Exercise` stores its
target range and increment, the app can compute and display the next target explicitly:

> Bench Press — 3×8 @ 135 lb. Hit 3×10 to earn 140 lb.

This turns the log from a passive record into a prescription, and it's the feature that
most directly replaces the mental arithmetic currently done in Apple Notes.

### Two views of progress

Because variations rotate, a single exercise's chart is sparse and noisy on its own. So
progress is tracked at two levels from the same set data:

- **Per-exercise e1RM over time** — "am I getting stronger at bench press"
- **Per-muscle-group weekly volume** — absorbs the rotation, answers "am I training
  back enough" regardless of which back movement was used that day

---

## The math

### Recovery score
Rolling 60-day baseline per metric, then z-score the most recent night's value
against it:

```
z = (today − μ₆₀) / σ₆₀
```

Weighted composite across HRV (heaviest weight), resting HR, respiratory rate, wrist
temperature deviation, and sleep debt. Every component surfaces individually in the
"Why?" view.

### Cardiovascular load — TRIMP (Banister)
```
TRIMP = duration × HRr × 0.64 × e^(1.92 × HRr)
where HRr = (HRavg − HRrest) / (HRmax − HRrest)
```

### Mechanical load
```
volume load = Σ (weight × reps)          per muscle group
e1RM        = weight × (1 + reps/30)     Epley
```
Optionally RPE-weighted, since 5 reps at RPE 9 is not the same stimulus as 5 at RPE 6.

### Acute:chronic workload ratio
```
ACWR = 7-day rolling load / 28-day rolling load
```
Roughly: 0.8–1.3 is the sweet spot, above ~1.5 is associated with elevated injury
risk. This is the single most useful metric that consumer apps don't show.

### Training monotony (Foster)
```
monotony = mean(daily load) / stdev(daily load)
```
High monotony — training the same amount every day with no variation — is itself a
risk factor.

---

## Build sequence

Ordered so there is a working app on the phone early, then capability layered on.

1. **Xcode setup** — install, create SwiftUI + SwiftData project, run on device
2. **HealthKit ingestion** — authorization, queries, anchored incremental sync
3. **Strength logging** — data model plus a fast set-entry UI
4. **Recovery engine** — baselines and z-scores
5. **Strain + load engine** — TRIMP, volume load, ACWR, monotony
6. **Dashboard + charts** — Today view, Swift Charts trends, transparency view
7. **Validation** — unit tests against hand-computed values, sanity-check against real history

## Stretch goals

- Home Screen widget showing today's recovery
- Live Activity during a logged lifting session
- Apple Watch companion app for logging sets at the rack
- Per-muscle-group fatigue heatmap
- Plateau detection on e1RM trends

---

## What this demonstrates on a resume

> Built an iOS training-analytics engine computing TRIMP-based cardiovascular load,
> mechanical volume load, and acute:chronic workload ratios from raw HealthKit
> biometric streams, with rolling z-score baselines for recovery scoring.

Skills evidenced: Swift, SwiftUI, SwiftData, HealthKit, Swift Charts, time-series
statistics, unit testing, and applied sports science. The statistical modelling
connects directly to the quantitative side of a CS + Economics degree.
