#!/usr/bin/swift
// WakeSpotterTests.swift — standalone test script for WakeSpotter.matchesWake(_:)
// Run from repo root:
//   swift NotchBuddy/Tests/WakeSpotterTests.swift

import Foundation

// ── Copy of WakeSpotter.matchesWake from WakeSpotter.swift ───────────────────
// Keep in sync with Sources/App/Voice/WakeSpotter.swift WakeSpotter.matchesWake.

func matchesWake(_ raw: String) -> Bool {
    var text = raw.lowercased()
        .components(separatedBy: CharacterSet.punctuationCharacters)
        .joined()
        .trimmingCharacters(in: .whitespaces)

    text = text
        .replacingOccurrences(of: "cuckoo",   with: "coucou")
        .replacingOccurrences(of: "kuku",     with: "coucou")
        .replacingOccurrences(of: "kucou",    with: "coucou")
        .replacingOccurrences(of: "cou cou",  with: "coucou")
        .replacingOccurrences(of: "okay",     with: "ok")
        .replacingOccurrences(of: "o k ",     with: "ok ")

    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }

    if text == "coucou" { return true }

    let wakePrefixes = ["ok coucou", "hey coucou"]
    for prefix in wakePrefixes {
        if text == prefix               { return true }
        if text.hasPrefix(prefix + " ") { return true }
    }

    return false
}

// ── Test table ────────────────────────────────────────────────────────────────

struct Case {
    let input:    String
    let expected: Bool
    let label:    String
}

let cases: [Case] = [
    // ── Should trigger ────────────────────────────────────────────────────────
    Case(input: "ok coucou",                 expected: true,  label: "canonical lowercase"),
    Case(input: "OK Coucou",                 expected: true,  label: "canonical mixed-case"),
    Case(input: "OK COUCOU",                 expected: true,  label: "all caps"),
    Case(input: "okay coucou",               expected: true,  label: "okay variant"),
    Case(input: "Okay Coucou",               expected: true,  label: "okay mixed-case"),
    Case(input: "ok cuckoo",                 expected: true,  label: "phonetic: cuckoo"),
    Case(input: "ok kuku",                   expected: true,  label: "phonetic: kuku"),
    Case(input: "ok cou cou",                expected: true,  label: "spaced: cou cou"),
    Case(input: "hey coucou",                expected: true,  label: "hey prefix"),
    Case(input: "Hey Coucou",                expected: true,  label: "hey mixed-case"),
    Case(input: "coucou",                    expected: true,  label: "standalone"),
    Case(input: "COUCOU",                    expected: true,  label: "standalone caps"),
    // Wake + command (recognizer may capture command words after wake phrase)
    Case(input: "ok coucou add github",      expected: true,  label: "wake + command words"),
    Case(input: "ok coucou ouvre figma",     expected: true,  label: "wake + french command"),

    // ── Should NOT trigger ────────────────────────────────────────────────────
    Case(input: "coucou ça va",              expected: false, label: "greeting sentence"),
    Case(input: "coucou comment tu vas",     expected: false, label: "greeting with more words"),
    Case(input: "ok google",                 expected: false, label: "other wake word"),
    Case(input: "hey siri",                  expected: false, label: "other assistant"),
    Case(input: "comment ça va",             expected: false, label: "unrelated sentence"),
    Case(input: "",                          expected: false, label: "empty string"),
    Case(input: "bonjour coucou",            expected: false, label: "coucou not at known prefix"),
    Case(input: "salut",                     expected: false, label: "unrelated word"),
    Case(input: "okkkk coucou",              expected: false, label: "malformed ok"),
]

// ── Runner ────────────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

for c in cases {
    let got = matchesWake(c.input)
    if got == c.expected {
        print("✓  \(c.label)")
        passed += 1
    } else {
        print("✗  \(c.label)")
        print("   input:    \"\(c.input)\"")
        print("   expected: \(c.expected), got: \(got)")
        failed += 1
    }
}

print("\n\(passed)/\(passed + failed) tests passed.")
if failed > 0 { exit(1) }
