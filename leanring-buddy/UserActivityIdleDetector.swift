//
//  UserActivityIdleDetector.swift
//  leanring-buddy
//
//  Monitors keyboard and mouse activity to detect when the user has
//  paused after completing an action. Used by tutor mode to trigger
//  observations at natural break points instead of on a fixed timer.
//

import AppKit
import Combine

@MainActor
final class UserActivityIdleDetector: ObservableObject {
    /// Seconds of inactivity before the user is considered idle.
    static let idleThresholdSeconds: TimeInterval = 3.0

    /// True when the user has been idle for longer than the threshold
    /// AND has performed at least one action since the last observation.
    @Published private(set) var isUserIdle: Bool = false

    /// Timestamp of the most recent keyboard or mouse event.
    private var lastUserInputTimestamp: Date = Date()

    /// Whether the user has done anything since the last observation.
    /// Prevents repeated triggers while user is AFK or listening to TTS.
    private var hasUserActedSinceLastObservation: Bool = true

    private var globalEventMonitor: Any?
    private var idleCheckTimer: Timer?

    func start() {
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true

        // Monitor keyboard and mouse events globally to track user activity
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                       .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordUserActivity()
            }
        }

        // Lightweight poll to evaluate idle state (~2x per second)
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
    /// flag so the next observation requires fresh user input first.
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
