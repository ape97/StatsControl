import SwiftUI

/// Second page in the menu: login item, compact bar and version – the app is not meant to do more.
struct SettingsPage: View {
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                RoundIconButton(symbol: "chevron.left", size: 24, help: "Back", action: back)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 2)

            Module {
                HStack {
                    SettingLabel(symbol: "power", title: "Open at Login", tint: .green)
                    Spacer()
                    Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                        .labelsHidden()
                        .toggleStyle(.setting)
                        .controlSize(.small)
                        .help("Start Stats Control automatically when you log in")
                }
                SettingNote("Starts Stats Control automatically when you log in.")
            }

            Module {
                VStack(spacing: 8) {
                    HStack {
                        SettingLabel(symbol: "arrow.right.and.line.vertical.and.arrow.left", title: "Compact Menu Bar", tint: .blue)
                        Spacer()
                        Toggle("Compact Menu Bar", isOn: Binding(get: { model.compactBar }, set: { model.compactBar = $0 }))
                            .labelsHidden()
                            .toggleStyle(.setting)
                            .controlSize(.small)
                            .help("Show only one value in the menu bar. Values at or above the threshold appear next to it; hover to see all three.")
                    }
                    HStack {
                        Text("Show").font(.system(size: 12)).padding(.leading, 30)
                        Spacer()
                        Picker("Show", selection: Binding(get: { model.compactMetric }, set: { model.compactMetric = $0 })) {
                            Text("CPU").tag(Metric.cpu)
                            Text("GPU").tag(Metric.gpu)
                            Text("RAM").tag(Metric.memory)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Value shown while all values are below the threshold")
                    }
                    HStack {
                        Text("Threshold").font(.system(size: 12)).padding(.leading, 30)
                        Spacer()
                        Text("\(model.compactThreshold) %").font(.system(size: 12).monospacedDigit())
                        Stepper("Threshold", value: Binding(get: { model.compactThreshold }, set: { model.compactThreshold = $0 }),
                                in: 10...90, step: 5)
                            .labelsHidden()
                            .controlSize(.small)
                            .help("Values at or above this percentage appear in the menu bar")
                    }
                    .disabled(!model.compactBar)
                    .opacity(model.compactBar ? 1 : 0.45)
                    SettingNote("Shows only the value chosen under Show. CPU, GPU or RAM at or above the threshold appear next to it; hover the menu bar to see all three.")
                }
            }

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                Spacer()
                Text("Updates every \(Int(AppModel.interval)) s")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
    }
}
