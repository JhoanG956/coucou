#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou Flow → Settings: the key, the permission, the recognition and the history.
struct HubSettingsPage: View {
    @ObservedObject private var flow = FlowDictation.shared
    @ObservedObject private var store = FlowStore.shared
    @AppStorage("dictationLanguage") private var language = MacDictation.automatic
    @State private var confirmClear = false

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.settings")) {
            HubLabel(String(localized: "hub.settings.keys"))
            HubCard {
                HubRow(title: String(localized: "flow.enable")) {
                    Toggle("", isOn: $flow.isEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.hold"),
                       detail: flow.key == .fn ? String(localized: "flow.fn-help") : nil) {
                    Picker("", selection: $flow.key) {
                        ForEach(FlowKey.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.handsfree"),
                       detail: String(localized: "hub.settings.handsfree-detail")) {
                    HubKeyCap(text: "\(flow.key.symbol) \(flow.key.symbol)")
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.paste-again"),
                       detail: String(localized: "hub.settings.paste-again-detail")) {
                    HubKeyCap(text: "⌃⌘V")
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.cancel")) {
                    HubKeyCap(text: String(localized: "hub.key-esc"))
                }
            }

            HubLabel(String(localized: "hub.settings.permission"))
            HubCard {
                if flow.trusted {
                    Label(String(localized: "flow.access-ok"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.green)
                } else {
                    Text("flow.accessibility")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#C7CAD0"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "flow.accessibility-open")) { flow.openAccessibilitySettings() }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }

            HubLabel(String(localized: "hub.settings.recognition"))
            HubCard {
                HubRecognitionSettings(language: $language)
            }

            HubLabel(String(localized: "hub.settings.privacy"))
            HubCard {
                HubRow(title: String(localized: "hub.settings.keep")) {
                    Picker("", selection: $store.keepDays) {
                        Text("hub.keep.none").tag(0)
                        Text("hub.keep.week").tag(7)
                        Text("hub.keep.month").tag(30)
                        Text("hub.keep.year").tag(365)
                        Text("hub.keep.forever").tag(-1)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                HubDivider()
                HStack(spacing: 8) {
                    Button(String(localized: "hub.settings.clear-history")) { store.clearHistory() }
                        .buttonStyle(HubButtonStyle())
                    Button(String(localized: "hub.settings.clear-all")) { confirmClear = true }
                        .buttonStyle(HubButtonStyle())
                }
                Text("hub.settings.privacy-text")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { flow.recheckTrust() }
        .alert(String(localized: "hub.settings.clear-all-confirm"), isPresented: $confirmClear) {
            Button(String(localized: "hub.settings.clear-all"), role: .destructive) { store.clearEverything() }
            Button(String(localized: "hub.cancel"), role: .cancel) {}
        }
    }
}

/// A key drawn like a keycap.
struct HubKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
    }
}

/// How the voice becomes text: the Mac's recognizer and its language.
struct HubRecognitionSettings: View {
    @Binding var language: String

    var body: some View {
        HubRow(title: String(localized: "hub.settings.engine-apple"),
               detail: String(localized: "hub.settings.engine-apple-detail")) {
            EmptyView()
        }
        HubDivider()
        HubRow(title: String(localized: "Dictation language")) {
            Picker("", selection: $language) {
                Text("Automatic").tag(MacDictation.automatic)
                ForEach(MacDictation.allLanguages, id: \.self) { id in
                    Text(MacDictation.name(of: id)).tag(id)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
    }
}
#endif
