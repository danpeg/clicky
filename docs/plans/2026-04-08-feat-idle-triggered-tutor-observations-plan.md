---
title: "feat: idle-triggered tutor observations — teach after actions, not on a timer"
type: feat
status: active
date: 2026-04-08
---

# Idle-Triggered Tutor Observations

## Overview

The 30-second fixed timer for tutor mode feels robotic. A tutor should speak when the user *finishes doing something* — not on a clock. This replaces the fixed interval with an idle-detection trigger: when the user stops moving their mouse and typing for a few seconds, Clicky takes that as "they just finished an action" and observes.

## The Problem

The 30-second polling loop creates two bad scenarios:
1. **Interrupts mid-action** — user is actively clicking through menus and Clicky starts talking
2. **Too slow after actions** — user finishes a task, waits awkwardly for up to 30 seconds before Clicky notices

The ideal cadence: observe *right after* the user pauses, which signals they completed a step and are ready for guidance.

## Proposed Solution

**An idle detector that triggers tutor observations after N seconds of no keyboard/mouse activity.**

```
User Activity Timeline:
  ████░░░░░░████████░░░░░░░░████░░░░░░░░░░░
  ^active   ^idle    ^active  ^idle    ^idle
            3s→obs           3s→obs   3s→obs
```

### How It Works

1. Monitor all keyboard and mouse events via an `NSEvent` global monitor
2. Track the timestamp of the last user input
3. After tutor mode is enabled, run a lightweight polling timer (~500ms)
4. When `now - lastInputTimestamp > idleThresholdSeconds` AND no observation is already in flight, fire `performTutorObservation()`
5. After an observation completes (TTS finishes), require fresh user activity before the next observation — don't fire again just because they're still idle

### Key Behaviors

- **Idle threshold: 3 seconds.** Long enough that mid-action pauses (moving mouse between menus) don't trigger, short enough to feel responsive after completing a step.
- **Cooldown after observation.** After Clicky speaks, the idle detector resets and waits for the user to *do something* before it can fire again. This prevents Clicky from talking every 3 seconds while the user listens.
- **30-second fallback removed.** The fixed timer is replaced entirely by idle detection. If the user is idle for a very long time (AFK), Clicky stays quiet — that's correct behavior, not a bug.
- **Same pause conditions.** Skip observation if `voiceState != .idle` or TTS is playing (same as current loop).

## What Changes

### 1. New: `UserActivityIdleDetector.swift`

A standalone class that monitors user input and publishes idle state.

```swift
@MainActor
final class UserActivityIdleDetector: ObservableObject {
    /// Seconds of inactivity before the user is considered idle.
    static let idleThresholdSeconds: TimeInterval = 3.0

    /// True when the user has been idle for longer than the threshold.
    @Published private(set) var isUserIdle: Bool = false

    /// Timestamp of the most recent keyboard or mouse event.
    private var lastUserInputTimestamp: Date = Date()

    /// Whether the user has done *anything* since the last observation.
    /// Prevents repeated triggers while user is AFK.
    private var hasUserActedSinceLastObservation: Bool = true

    private var globalEventMonitor: Any?
    private var idleCheckTimer: Timer?

    func start() {
        lastUserInputTimestamp = Date()

        // Monitor keyboard and mouse events globally
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                       .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] _ in
            self?.recordUserActivity()
        }

        // Lightweight poll to check idle state (~2x per second)
        idleCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateIdleState()
            }
        }
    }

    func stop() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        isUserIdle = false
    }

    /// Called after a tutor observation completes. Resets the activity
    /// flag so the next observation requires fresh user input.
    func observationDidComplete() {
        hasUserActedSinceLastObservation = false
        isUserIdle = false
    }

    private func recordUserActivity() {
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true
        isUserIdle = false
    }

    private func evaluateIdleState() {
        let secondsSinceLastInput = Date().timeIntervalSince(lastUserInputTimestamp)
        let isNowIdle = secondsSinceLastInput >= Self.idleThresholdSeconds
                        && hasUserActedSinceLastObservation
        if isNowIdle != isUserIdle {
            isUserIdle = isNowIdle
        }
    }
}
```

### 2. CompanionManager.swift

**Replace the timer-based loop with idle-triggered observations.**

Remove:
- `tutorObservationTask` / `tutorCheckIntervalSeconds`
- `startTutorObservationLoop()` / `stopTutorObservationLoop()` timer loop

Add:
- `let userActivityIdleDetector = UserActivityIdleDetector()`
- A Combine subscription on `userActivityIdleDetector.$isUserIdle` that fires `performTutorObservation()` when idle transitions to `true`
- Call `userActivityIdleDetector.observationDidComplete()` after TTS finishes in `performTutorObservation()`

```swift
// In setTutorModeEnabled:
if enabled {
    userActivityIdleDetector.start()
    bindTutorIdleObservation()
} else {
    userActivityIdleDetector.stop()
    tutorIdleCancellable?.cancel()
}

// New binding:
private var tutorIdleCancellable: AnyCancellable?

private func bindTutorIdleObservation() {
    tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
        .filter { $0 == true }
        .sink { [weak self] _ in
            guard let self,
                  self.voiceState == .idle,
                  !(self.elevenLabsTTSClient.isPlaying) else { return }
            Task {
                await self.performTutorObservation()
                self.userActivityIdleDetector.observationDidComplete()
            }
        }
}
```

**Update `performTutorObservation()`:** No changes needed — it already captures, sends to Claude, plays TTS. The only addition is the `observationDidComplete()` call after TTS finishes (handled in the sink above).

**Update `stop()`:** Add `userActivityIdleDetector.stop()`.

**Update `start()`:** Resume idle detector if tutor mode was previously enabled.

## Acceptance Criteria

- [x] Tutor observations trigger after ~3 seconds of keyboard/mouse inactivity
- [x] No observation fires while user is actively typing or moving mouse
- [x] After Clicky speaks, it waits for the user to act before observing again
- [x] Observations still pause during push-to-talk and TTS playback
- [x] Toggle off stops the idle detector (no event monitoring)
- [x] Push-to-talk still works normally alongside idle-triggered tutor mode
- [x] No fixed 30-second timer — idle detection is the only trigger

## Design Decisions

**NSEvent global monitor, not CGEvent tap.** The app already has a CGEvent tap for push-to-talk, and macOS limits how many taps a process can have. `NSEvent.addGlobalMonitorForEvents` is simpler, doesn't require accessibility permission beyond what's already granted, and is sufficient for idle detection (we don't need to intercept or modify events).

**3-second threshold.** Tested mentally against real workflows: opening a menu takes <1s, reading a dialog takes 2-3s, completing a multi-click action takes 1-2s. 3 seconds catches the natural pause after most actions without triggering during brief pauses between clicks. This should be tested and potentially made configurable later.

**Cooldown via activity flag.** Without this, Clicky would fire every 3 seconds while the user is AFK (e.g. reading what Clicky said). The `hasUserActedSinceLastObservation` flag ensures: observe → user acts → pause → observe. Never: observe → pause → observe → pause.

**No fixed timer fallback.** The 30-second timer was a crutch. If the user is truly idle (AFK, reading), Clicky should stay quiet. The idle detector naturally fires when the user returns and pauses.

## Key Files

| File | Change |
|------|--------|
| `UserActivityIdleDetector.swift` (new) | Idle detection via NSEvent monitor + polling timer |
| `CompanionManager.swift` | Replace timer loop with idle-triggered Combine subscription |

## Risks

- **3-second threshold may be wrong.** Too short = chatty, too long = sluggish. Mitigation: easy to tune, could expose in settings later.
- **NSEvent monitor may miss some events.** Certain full-screen apps or games may not propagate events to global monitors. Mitigation: acceptable for tutor mode's target use case (learning productivity apps).
- **CPU cost of 500ms polling timer.** Negligible — it's a single timestamp comparison. The NSEvent callback is also lightweight (just records a date).
