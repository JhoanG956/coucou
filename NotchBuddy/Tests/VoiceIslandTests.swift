#!/usr/bin/swift
// VoiceIslandTests.swift — standalone tests for IslandStateMachine listening state.
// Run from repo root:
//   swift NotchBuddy/Tests/VoiceIslandTests.swift
//
// Copies the FSM logic (voice-specific paths only) to avoid Xcode dependencies.

import Foundation

// ── Minimal FSM copy for testing ──────────────────────────────────────────────

enum FSMState: Equatable {
    case hidden, petit, home, coucou, listening
}

class TestFSM {
    var state: FSMState = .hidden
    var transitions: [(from: FSMState, to: FSMState)] = []

    private func transition(to new: FSMState) {
        guard new != state else { return }
        let old = state
        state = new
        transitions.append((from: old, to: new))
    }

    func voiceWoke() {
        transition(to: .listening)
    }

    func voiceFinished() {
        guard state == .listening else { return }
        transition(to: .petit)
    }

    func collapse() {
        guard state == .home || state == .coucou || state == .listening else { return }
        transition(to: .petit)
    }

    func mouseLeft() {
        switch state {
        case .hidden:    break
        case .petit:     break  // simplified — real FSM schedules a timer
        case .home:      break  // simplified
        case .coucou:    break  // simplified
        case .listening: break  // must NOT schedule any timer
        }
    }

    func mouseEntered() {
        switch state {
        case .hidden:    transition(to: .petit)
        case .petit:     break
        case .home:      break
        case .coucou:    break
        case .listening: break  // already open
        }
    }

    func click() {
        guard state == .petit || state == .hidden else { return }
        transition(to: .home)
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("✓  \(label)")
        passed += 1
    } else {
        print("✗  \(label)")
        failed += 1
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

do {
    // Wake from hidden
    let fsm = TestFSM()
    fsm.voiceWoke()
    check("voiceWoke from hidden → listening", fsm.state == .listening)
}

do {
    // Wake from petit
    let fsm = TestFSM()
    fsm.state = .petit
    fsm.voiceWoke()
    check("voiceWoke from petit → listening", fsm.state == .listening)
}

do {
    // Wake from home
    let fsm = TestFSM()
    fsm.state = .home
    fsm.voiceWoke()
    check("voiceWoke from home → listening", fsm.state == .listening)
}

do {
    // Finish after wake
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.voiceFinished()
    check("voiceFinished → petit", fsm.state == .petit)
}

do {
    // voiceFinished is a no-op when not in listening
    let fsm = TestFSM()
    fsm.state = .home
    fsm.voiceFinished()
    check("voiceFinished from home → no-op (stays home)", fsm.state == .home)
}

do {
    // voiceFinished is a no-op from petit
    let fsm = TestFSM()
    fsm.state = .petit
    fsm.voiceFinished()
    check("voiceFinished from petit → no-op (stays petit)", fsm.state == .petit)
}

do {
    // collapse() while listening → petit
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.collapse()
    check("collapse while listening → petit", fsm.state == .petit)
}

do {
    // click() while listening → no-op (already expanded)
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.click()
    check("click while listening → no-op (stays listening)", fsm.state == .listening)
}

do {
    // mouseLeft while listening → no timer; state unchanged
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.mouseLeft()
    check("mouseLeft while listening → stays listening", fsm.state == .listening)
}

do {
    // mouseEntered while listening → no-op
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.mouseEntered()
    check("mouseEntered while listening → stays listening", fsm.state == .listening)
}

do {
    // Transition sequence: hidden → listening → petit
    let fsm = TestFSM()
    fsm.voiceWoke()
    fsm.voiceFinished()
    let seq = fsm.transitions.map { "\($0.from)→\($0.to)" }
    check("full sequence hidden→listening→petit",
          seq == ["hidden→listening", "listening→petit"])
}

do {
    // Wake while already listening → stays listening (transition(to:) is idempotent)
    let fsm = TestFSM()
    fsm.voiceWoke()
    let before = fsm.transitions.count
    fsm.voiceWoke()
    check("double voiceWoke → no second transition", fsm.transitions.count == before)
    check("double voiceWoke → still listening", fsm.state == .listening)
}

// ── Summary ───────────────────────────────────────────────────────────────────
print("\n\(passed)/\(passed + failed) tests passed.")
if failed > 0 { exit(1) }
