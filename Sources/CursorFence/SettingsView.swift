import AppKit
import FenceCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Label(model.statusLine, systemImage: model.statusLine.hasPrefix("On") ? "lock.fill" : "lock.open")
                    .foregroundStyle(model.statusLine.hasPrefix("On") ? .primary : .secondary)
                if !model.accessibilityGranted {
                    HStack {
                        Text("Cursor Fence needs Accessibility to hold the pointer.")
                        Spacer()
                        Button("Open Accessibility Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }

            Section("Fenced display") {
                Picker("Keep the pointer off", selection: $model.fencedUUID) {
                    Text("None").tag(String?.none)
                    ForEach(model.displays) { d in
                        Text(d.label).tag(String?.some(d.id))
                    }
                    if let uuid = model.fencedUUID, model.fencedDisplay == nil {
                        Text("\(model.fencedName ?? "Remembered display") — not connected").tag(String?.some(uuid))
                    }
                }
                Text("Remembered by the display's own ID, so it survives reconnecting and rearranging. Leaving the fenced display is always free.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Release keys") {
                HStack(spacing: 8) {
                    ForEach(ReleaseKeys.ordered, id: \.symbol) { entry in
                        Toggle(isOn: Binding(
                            get: { model.releaseKeys.contains(entry.key) },
                            set: { on in
                                if on { model.releaseKeys.insert(entry.key) } else { model.releaseKeys.remove(entry.key) }
                            })) {
                            Text(entry.symbol).font(.title3).frame(minWidth: 28)
                        }
                        .toggleStyle(.button)
                        .help(entry.name)
                    }
                }
                Text(model.releaseKeys.isEmpty
                     ? "No keys chosen: the pointer can never cross."
                     : "Hold \(model.releaseKeys.symbols) to move the pointer onto the fenced display.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                LabeledContent("Guard band") {
                    HStack {
                        Slider(value: $model.band, in: 80...800, step: 20)
                        Text("\(Int(model.band)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Text("Within this distance of the wall the pointer is driven by Cursor Fence, so no single flick can reach the fenced display. It widens on its own for fast motion.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Mechanism", selection: $model.mechanism) {
                    Text("Disassociate near the wall (default)").tag(Mechanism.disassociate)
                    Text("Rewrite only (test mode)").tag(Mechanism.rewriteOnly)
                }
            }

            Section("Diagnostics") {
                let s = model.stats
                LabeledContent("Rebounds", value: "\(s["contacts"] ?? 0)")
                LabeledContent("Breaches", value: "\(s["breaches"] ?? 0)")
                LabeledContent("Glows shown / refused", value: "\(s["glowShown"] ?? 0) / \(s["glowRefused"] ?? 0)")
                LabeledContent("Tap restarts / watchdog trips", value: "\(s["tapRestarts"] ?? 0) / \(s["watchdogTrips"] ?? 0)")
                LabeledContent("Largest single move / closest engage",
                               value: "\(s["maxHardwareDeltaPt"] ?? 0) pt / \((s["closestEngagePt"] ?? -1) < 0 ? "—" : "\(s["closestEngagePt"]!) pt")")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
