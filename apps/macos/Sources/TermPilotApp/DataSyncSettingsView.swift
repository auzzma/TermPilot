import SwiftUI
import TermPilotCore
import TermPilotPersistence
import TermPilotSyncUI

@MainActor final class DataSyncCoordinator {
    static let shared = DataSyncCoordinator()
    private var task: Task<Void, Never>?
    static func call(_ data: Data) async throws -> Data {
        let preferenceRevision = PreferenceSaveQueue.shared.revision
        let directory = try VaultStore.applicationSupportDirectory().path
        let data = try await Task.detached(priority: .utility) {
            var request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            request["directory"] = directory
            return try JSONSerialization.data(withJSONObject: SharedCore.call(request))
        }.value
        if preferenceRevision == PreferenceSaveQueue.shared.revision, let value=try JSONSerialization.jsonObject(with:data) as? [String:Any], let preferences=value["preferences"] as? [String:Any] {
            for (field,key) in ["theme":"appearance","language":"language","fontSize":"terminalFontSize","fontFamily":"terminalFontName","fps":"remoteDesktopFrameRate","videoCodec":"remoteDesktopVideoCodec"] {
                if let value=preferences[field], !PreferenceSaveQueue.shared.hasPending(field), !NSDictionary(dictionary: ["value": UserDefaults.standard.object(forKey:key) ?? NSNull()]).isEqual(to: ["value": value]) { UserDefaults.standard.set(value,forKey:key) }
            }
        }
        return data
    }
    static func blocksTermination() async throws -> Bool {
        try await ConnectionPreparationService.run {
            let value = try SharedCore.call(["method":"sync.status", "directory":try VaultStore.applicationSupportDirectory().path])
            return (value["passwordChange"] as? [String:Any])?["active"] as? Bool == true
        }
    }
    func start() {
        guard task == nil else { return }
        task = Task {
            do {
                _ = try await Self.call(JSONSerialization.data(withJSONObject:["method":"sync.recover"]))
                NotificationCenter.default.post(name: .termPilotVaultDidChange, object:nil)
            } catch {
                // Keep the recovery marker for the next launch or manual retry.
            }
            let defaults=UserDefaults.standard
            var initial:[String:Any]=[:]
            for (field,key) in ["theme":"appearance","language":"language","fontSize":"terminalFontSize","fontFamily":"terminalFontName","fps":"remoteDesktopFrameRate","videoCodec":"remoteDesktopVideoCodec"] {if let value=defaults.object(forKey:key){initial[field]=value}}
            if let data=try? JSONSerialization.data(withJSONObject:["method":"sync.preferences","initial":true,"values":initial]) {_ = try? await Self.call(data)}
            while !Task.isCancelled {
                do {
                    let request = try JSONSerialization.data(withJSONObject: ["method":"sync.tick"])
                    let data = try await Self.call(request)
                    let result = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                    if result["skipped"] as? Bool != true {
                        NotificationCenter.default.post(name: .termPilotVaultDidChange, object:nil)
                    }
                } catch { /* The shared store retains retry status for the settings page. */ }
                try? await Task.sleep(for:.seconds(5))
            }
        }
    }
}

@MainActor func syncedPreference<T>(_ binding: Binding<T>, _ field: String) -> Binding<T> {
    Binding(get: { binding.wrappedValue }, set: { value in
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return }
        binding.wrappedValue = value
        PreferenceSaveQueue.shared.enqueue(data, field: field)
    })
}
struct DataSyncSettingsView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        DataSyncView(call:DataSyncCoordinator.call) {
            await state.refreshHosts()
            try? await state.refreshLocalWorkflows()
        }
    }
}
