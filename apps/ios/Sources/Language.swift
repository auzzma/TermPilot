import Foundation

enum MobileLanguage {
  static let english: [String: String] = {
    guard let url = Bundle.main.url(forResource: "MobileEnglish", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let values = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return values
  }()
  static var usesEnglish: Bool {
    let value = UserDefaults.standard.string(forKey: "TermPilot.language") ?? "zh-Hans"
    return value == "en"
      || (value == "system" && !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh"))
  }
}
/// Translates application labels only; remote output, commands and AI content stay verbatim.
func tr(_ label: String) -> String {
  MobileLanguage.usesEnglish ? MobileLanguage.english[label] ?? label : label
}

func trf(_ template: String, _ values: String...) -> String {
  let parts = tr(template).components(separatedBy: "{}")
  guard parts.count == values.count + 1 else { return tr(template) }
  return parts.enumerated().map { index, part in part + (index < values.count ? values[index] : "")
  }.joined()
}
