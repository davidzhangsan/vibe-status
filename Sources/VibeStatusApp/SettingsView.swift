import SwiftUI
import VibeStatusCore

struct SettingsView: View {
    @Bindable var model: DashboardModel
    @State private var hostToDelete: HostProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.showDashboard()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("Settings")
                    .font(.headline)

                Spacer()

                Color.clear
                    .frame(width: 44, height: 1)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Remote Hosts")
                            .font(.headline)

                        ForEach($model.hosts) { $host in
                            VStack(alignment: .trailing, spacing: 4) {
                                HostEditorRow(
                                    host: $host,
                                    validationState: model.validationStates[host.id] ?? .idle,
                                    validate: { model.validate(host: host) },
                                    invalidate: {
                                        model.invalidateValidation(hostID: host.id)
                                    }
                                )

                                Button("Remove", role: .destructive) {
                                    hostToDelete = host
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }

                        Button {
                            model.showOnboarding()
                        } label: {
                            Label("Add from SSH Config", systemImage: "plus")
                        }
                    }

                    Divider()

                    Toggle("Launch Vibe Status at login", isOn: $model.launchAtLogin)

                    Text("Session names, paths, statuses, and diagnostics stay in memory and are discarded when the app quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Quit Vibe Status") {
                    NSApplication.shared.terminate(nil)
                }

                Spacer()

                Button("Save") {
                    model.saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSaveSettings)
            }
            .padding(14)
        }
        .confirmationDialog(
            "Remove \(hostToDelete?.displayName ?? "remote host")?",
            isPresented: Binding(
                get: { hostToDelete != nil },
                set: { if !$0 { hostToDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard
                    let hostToDelete,
                    let index = model.hosts.firstIndex(of: hostToDelete)
                else {
                    return
                }
                model.removeHosts(at: IndexSet(integer: index))
                self.hostToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                hostToDelete = nil
            }
        }
    }
}
