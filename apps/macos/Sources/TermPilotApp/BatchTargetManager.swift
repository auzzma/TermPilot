import AppKit
import SwiftUI
import TermPilotDomain

struct BatchTargetDefaults {
    var ipList = ""
    var port = 22
    var credentialID: UUID?
    var elevation = "none"
    var password = ""
}

struct BatchTargetManager: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var controller: BatchJobController
    @Environment(\.dismiss) private var dismiss
    @Binding var defaults: BatchTargetDefaults
    @State private var showingHostPicker = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.string("Manage hosts")).font(.title2.bold())
            Text(AppLocalization.string("Defaults apply to newly added hosts. Each host can use its own settings.")).foregroundStyle(.secondary)
            if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red).textSelection(.enabled) }
            targetForm.disabled(controller.running)
            HStack { Spacer(); Button(AppLocalization.string("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 850, height: 620).textFieldStyle(.roundedBorder)
        .sheet(isPresented: $showingHostPicker) { BatchHostPicker(hosts: state.hosts, groups: state.groups, added: controller.targets.map(\.host), onAdd: addHosts) }
    }
    private var targetForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("Add hosts")).font(.headline)
            BatchTextEditor(text: $defaults.ipList, label: AppLocalization.string("IP list"), monospaced: true)
                .frame(height: 80).border(.secondary.opacity(0.25))
            Text(AppLocalization.string("192.168.1.10 · 192.168.1.11:2222 · [::1]:22")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(AppLocalization.string("Port"), value: $defaults.port, format: .number).frame(width: 85)
                Picker(AppLocalization.string("Credentials"), selection: $defaults.credentialID) { Text(AppLocalization.string("Select credential")).tag(nil as UUID?); ForEach(state.credentials) { c in Text("\(c.label) · \(c.username)").tag(Optional(c.id)) } }
                elevationPicker($defaults.elevation)
            }
            SecureField(AppLocalization.string("Elevation password override"), text: $defaults.password)
            HStack {
                Button(AppLocalization.string("Add IPs")) { do { try controller.addIPs(defaults.ipList, port: defaults.port, credential: defaults.credentialID, elevation: defaults.elevation, password: defaults.password); defaults.ipList = "" } catch { controller.error = error.localizedDescription } }
                Button(AppLocalization.string("Add saved host")) { showingHostPicker = true }
                Button(AppLocalization.string("Apply defaults to all")) {
                    for i in controller.targets.indices { controller.targets[i].elevation = defaults.elevation; controller.targets[i].elevationPassword = defaults.password; if let credentialID = defaults.credentialID { controller.targets[i].host.credentialID = credentialID; controller.targets[i].host.username = ""; controller.targets[i].host.elevationPassword = nil } }
                }
            }
            Divider().padding(.vertical, 6)
            HStack {
                Text(AppLocalization.string("Selected hosts")).font(.headline)
                Spacer()
                Button {
                    controller.targets.removeAll()
                } label: {
                    Label(AppLocalization.string("Clear selected hosts"), systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .disabled(controller.targets.isEmpty)
                .accessibilityIdentifier("batch-clear-selected-hosts")
            }
            ScrollView {
                LazyVStack {
                    ForEach($controller.targets) { $target in
                        HStack {
                            Text("\(target.host.hostname.contains(":") ? "[\(target.host.hostname)]" : target.host.hostname):\(target.host.port)").font(.system(.caption, design: .monospaced)).frame(width: 160, alignment: .leading)
                            Picker(AppLocalization.string("Credentials"), selection: Binding(get: { target.host.credentialID }, set: { target.host.credentialID = $0; if $0 != nil { target.host.username = "" }; target.host.elevationPassword = nil })) { Text(AppLocalization.string("Host credentials")).tag(nil as UUID?); ForEach(state.credentials) { c in Text(c.label).tag(Optional(c.id)) } }.labelsHidden()
                            elevationPicker($target.elevation).labelsHidden().frame(width: 105)
                            SecureField(AppLocalization.string("Use credential password"), text: $target.elevationPassword)
                            Button { controller.targets.removeAll { $0.id == target.id } } label: { Image(systemName: "xmark") }.help("Remove")
                        }
                    }
                }
            }.frame(minHeight: 120, maxHeight: .infinity)
            Text("\(controller.targets.count) \(AppLocalization.string("hosts selected · temporary IPs stay in this job"))").font(.caption).foregroundStyle(.secondary)
        }.padding(10)
    }
    private func elevationPicker(_ binding: Binding<String>) -> some View { Picker(AppLocalization.string("Elevation"), selection: binding) { Text(AppLocalization.string("No elevation")).tag("none"); Text(AppLocalization.string("sudo")).tag("sudo"); Text(AppLocalization.string("su")).tag("su") } }
    private func addHosts(_ hosts: [TermPilotDomain.Host]) { controller.append(hosts.filter { $0.connectionKind == .ssh }.map { BatchTarget(host: $0, elevation: defaults.elevation, elevationPassword: defaults.password, savedHostID: $0.id) }) }
}
