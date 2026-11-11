import SwiftUI
@MainActor func mobileSyncedPreference<T>(_ binding: Binding<T>, _ field:String, model:AppModel) -> Binding<T> {
    Binding(get:{binding.wrappedValue},set:{value in model.attempt {
        _ = try await model.call(["method":"sync.preferences","values":[field:value]])
        binding.wrappedValue=value
    }})
}
struct MobileDataSyncSettings: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        DataSyncView(call:{ data in
            let request=try JSONSerialization.jsonObject(with:data) as? JSON ?? [:]
            return try JSONSerialization.data(withJSONObject: await model.call(request))
        },changed:{await model.reload()})
        .navigationTitle(tr("数据同步")).navigationBarTitleDisplayMode(.inline)
    }
}
