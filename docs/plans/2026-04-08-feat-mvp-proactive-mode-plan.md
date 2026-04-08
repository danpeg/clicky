---
title: "feat: MVP tutor mode — Clicky proactively guides you through any app"
type: feat
status: active
date: 2026-04-08
---

# MVP Tutor Mode

## Overview

Add a "Tutor mode" toggle to Clicky. When enabled, Clicky becomes an active instructor — it periodically screenshots your screen, figures out what you're doing, and proactively guides you step by step. It points at buttons, explains what things do, suggests what to try next. No push-to-talk needed — Clicky initiates.

One mode. One toggle. No complexity.

## The Problem

Currently Clicky is 100% reactive — you push-to-talk, it responds. But the killer use case for a companion that can see your screen is **teaching**. Imagine opening a new app and Clicky immediately says "i see you just opened figma for the first time — see that toolbar on the left? let's start with the frame tool, it's how you create your canvas." That's what tutor mode does.

## Proposed Solution

**A polling loop that runs when tutor mode is ON:**

```
Every 30 seconds:
  1. Capture screenshot
  2. Send to Claude with tutor prompt
  3. Claude responds with guidance (always — tutor mode never stays silent)
  4. Play via TTS + pointing, same as a normal response
```

### The Tutor System Prompt

```
you're clicky in tutor mode. the user wants to LEARN whatever software
they're currently using. you are their hands-on instructor who can see
their screen.

your job:
- proactively guide them step by step. don't wait to be asked
- if they just opened an app, welcome them and suggest where to start
- point at buttons, menus, and settings they should interact with.
  use [POINT] aggressively — a tutor who can point is 10x more useful
- after they complete a step, acknowledge it and tell them the next one
- if they go off track, gently redirect
- teach concepts as they become relevant, not all at once
- if they're doing well, say so and push them to the next level
- if the screen hasn't changed since your last observation, say something
  encouraging or suggest what to click next — don't repeat yourself

keep the warm clicky voice. short sentences. all lowercase, casual.
you're a helpful friend walking them through it, not a corporate trainer.

important: check conversation history to avoid repeating what you already
said. each observation should build on the last, not restart from scratch.
```

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  TutorObservationLoop (new)                             │
│                                                         │
│  Timer fires every 30 seconds                           │
│  ├─ Capture screenshot                                  │
│  ├─ Send to Claude with tutor prompt + history          │
│  └─ Play response via TTS + pointing (same pipeline)    │
│                                                         │
│  Pauses when:                                           │
│  ├─ User is push-to-talking (don't interrupt)           │
│  ├─ Clicky is already speaking (TTS playing)            │
│  ├─ voiceState != .idle                                 │
│  └─ App is in background / overlay hidden               │
└─────────────────────────────────────────────────────────┘
```

## What Changes

### 1. CompanionManager.swift

**Add property + setter** (~line 142, same pattern as other toggles):

```swift
/// Whether Clicky is in tutor mode — proactively guiding the user
/// through whatever software they're using.
@Published var isTutorModeEnabled: Bool = UserDefaults.standard.bool(forKey: "isTutorModeEnabled")

func setTutorModeEnabled(_ enabled: Bool) {
    isTutorModeEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "isTutorModeEnabled")
    if enabled {
        startTutorObservationLoop()
    } else {
        stopTutorObservationLoop()
    }
}
```

**Add the observation loop:**

```swift
private var tutorObservationTask: Task<Void, Never>?
private static let tutorCheckIntervalSeconds: Double = 30

private func startTutorObservationLoop() {
    stopTutorObservationLoop()
    tutorObservationTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.tutorCheckIntervalSeconds))
            guard let self, !Task.isCancelled else { return }

            // Don't interrupt active interactions
            guard self.voiceState == .idle,
                  !(self.elevenLabsTTSClient.isPlaying) else {
                continue
            }

            await self.performTutorObservation()
        }
    }
}

private func stopTutorObservationLoop() {
    tutorObservationTask?.cancel()
    tutorObservationTask = nil
}
```

**Add the observation method** (reuses existing screenshot + Claude pipeline):

```swift
private func performTutorObservation() async {
    do {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let labeledImages = screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }

        let historyForAPI = conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        }

        let (responseText, _) = try await claudeAPI.analyzeImageStreaming(
            images: labeledImages,
            systemPrompt: Self.tutorModeSystemPrompt,
            conversationHistory: historyForAPI,
            userPrompt: "observe the screen and guide me",
            onTextChunk: { _ in }
        )

        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return }

        let parseResult = Self.parsePointingCoordinates(from: trimmedResponse)
        let spokenText = parseResult.spokenText

        if isAutoCopyResponseEnabled {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(spokenText, forType: .string)
        }

        conversationHistory.append((
            userTranscript: "[tutor observation]",
            assistantResponse: spokenText
        ))

        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceState = .responding
            try await elevenLabsTTSClient.speakText(spokenText)
            voiceState = .idle
        }
    } catch {
        print("⚠️ Tutor observation error: \(error)")
    }
}
```

**Add the tutor system prompt:**

```swift
private static let tutorModeSystemPrompt = """
you're clicky in tutor mode. the user wants to LEARN whatever software they're currently using. you are their hands-on instructor who can see their screen.

your job:
- proactively guide them step by step. don't wait to be asked
- if they just opened an app, welcome them and suggest where to start
- point at buttons, menus, and settings they should interact with. use [POINT] aggressively — a tutor who can point is way more useful than one who just talks
- after they complete a step, acknowledge it and tell them the next one
- if they go off track, gently redirect
- teach concepts as they become relevant, not all at once
- if they're doing well, say so and push them to the next level
- if the screen hasn't changed since your last observation, say something encouraging or suggest what to click next — don't repeat yourself

keep the warm clicky voice. short sentences. all lowercase, casual. you're a helpful friend walking them through it, not a corporate trainer.

important: check conversation history to avoid repeating what you already said. each observation should build on the last, not restart from scratch.

element pointing:
use the same [POINT:x,y:label] format as normal mode. point at the specific UI element the user should interact with next. if the element is on a different screen, append :screenN.
"""
```

### 2. CompanionPanelView.swift

**Add toggle row:**

```swift
private var tutorModeToggleRow: some View {
    HStack {
        HStack(spacing: 8) {
            Image(systemName: "graduationcap")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            Text("Tutor mode")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }

        Spacer()

        Toggle("", isOn: Binding(
            get: { companionManager.isTutorModeEnabled },
            set: { companionManager.setTutorModeEnabled($0) }
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .tint(DS.Colors.accent)
        .scaleEffect(0.8)
    }
    .padding(.vertical, 4)
}
```

**Render it** in the panel body, next to the other toggles.

## Acceptance Criteria

- [x] "Tutor mode" toggle appears in menu panel (graduation cap icon)
- [x] Toggle defaults to OFF, persists via UserDefaults
- [x] When ON, Clicky screenshots every 30 seconds and proactively guides
- [x] Clicky points at UI elements the user should interact with
- [x] Each observation builds on the last (doesn't repeat itself)
- [x] Observations pause during push-to-talk and TTS playback
- [x] When OFF, no polling occurs (timer is cancelled)
- [x] Tutor observations are saved to conversation history
- [x] Push-to-talk still works normally alongside tutor mode

## Design Decisions

**Check interval: 30 seconds.** Active tutoring needs faster feedback than passive observation. 30 seconds gives the user time to act on the last instruction before the next one comes.

**Always speaks (no [SILENT] token).** In tutor mode, the user asked to be taught. Claude should always have something to say — even if it's "nice, you found the settings menu, now look for the connectors section." This is different from a passive watcher.

**Conversation history prevents repetition.** The "[tutor observation]" transcript markers let Claude see what it already said. The history cap (10 exchanges) keeps context manageable.

**Reuses existing infrastructure.** Same screenshot capture, same Claude API, same TTS pipeline, same [POINT] system. The only new code is the timer loop and the prompt.

## Risks

- **Talking too much.** Tutor mode speaks every 30 seconds by design. If the guidance isn't useful, it'll feel spammy. Mitigation: the prompt instructs Claude to build on prior observations, not repeat. Users can toggle off instantly.
- **API cost.** One Claude call every 30 seconds. With Sonnet + JPEG, ~$0.01/min. Mitigation: toggle is off by default, users opt in.
- **Pointing at wrong elements.** Clicky points using screenshot coordinates. If the user moves windows between screenshots, pointing may be stale. Mitigation: 10-second interval is short enough that screen state is usually current.

## Key Files

| File | Change |
|------|--------|
| `CompanionManager.swift:~142` | Add `isTutorModeEnabled` property + setter |
| `CompanionManager.swift` (new) | Add `tutorModeSystemPrompt` static string |
| `CompanionManager.swift` (new) | Add `startTutorObservationLoop()`, `stopTutorObservationLoop()`, `performTutorObservation()` |
| `CompanionPanelView.swift` | Add `tutorModeToggleRow` + render in panel |

## Future

- **Passive watch mode:** A second gear where Clicky only speaks on errors/stuck states. Same loop, different prompt with [SILENT] bias. Add later if needed.
- **Wiki integration:** Prepend domain-specific wiki pages to the tutor prompt for deeper knowledge (Cowork workflows, DaVinci techniques, etc.).
- **Subject picker:** "Tutor me on: [dropdown]" that loads different wiki contexts.
