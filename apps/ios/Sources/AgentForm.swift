import SwiftUI

struct AgentForm: View {
  let spec: JSON
  @Binding var values: JSON
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(spec.text("title", tr("填写信息"))).font(.headline)
      if !spec.text("error").isEmpty { Text(spec.text("error")).foregroundStyle(.red) }
      ForEach(spec.array("fields"), id: \.selfID) { field in
        let name = field.text("name")
        let label = field.text("label", name) + ((field["required"] as? Bool == true) ? " *" : "")
        if visible(field) {
          switch field.text("type") {
          case "checkbox":
            Toggle(
              label,
              isOn: Binding(get: { values[name] as? Bool ?? false }, set: { values[name] = $0 }))
          case "select", "radio":
            Picker(label, selection: binding(name)) {
              Text(tr("请选择")).tag("")
              ForEach(field.array("options"), id: \.optionID) { option in
                Text(option.text("label")).tag(option.text("value"))
              }
            }
          case "password": SecureField(label, text: binding(name)).textFieldStyle(.roundedBorder)
          case "number":
            TextField(tr(label), text: binding(name)).keyboardType(.decimalPad).textFieldStyle(
              .roundedBorder)
          case "textarea":
            TextField(tr(label), text: binding(name), axis: .vertical).lineLimit(3...10)
              .textFieldStyle(
                .roundedBorder)
          default:
            TextField(tr(label), text: binding(name)).textFieldStyle(.roundedBorder)
              .textInputAutocapitalization(.never)
          }
        }
      }
    }.onAppear {
      for field in spec.array("fields") where values[field.text("name")] == nil {
        values[field.text("name")] = spec.object("values")[field.text("name")] ?? field["default"]
      }
    }
  }
  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { values[key].map { String(describing: $0) } ?? "" }, set: { values[key] = $0 })
  }
  private func visible(_ field: JSON) -> Bool {
    let condition = field.object("visibleWhen")
    guard !condition.isEmpty else { return true }
    let value = values[condition.text("field")] ?? NSNull()
    if let expected = condition["equals"] {
      return String(describing: value) == String(describing: expected)
    }
    if let expected = condition["notEquals"] {
      return String(describing: value) != String(describing: expected)
    }
    let truth =
      !(value is NSNull) && String(describing: value) != "false" && String(describing: value) != ""
      && String(describing: value) != "0"
    return condition["falsy"] as? Bool == true ? !truth : truth
  }
}
extension Dictionary where Key == String, Value == Any {
  var optionID: String { text("value") }
}
