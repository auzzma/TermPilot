import Foundation
import CTermPilotCore

public struct SharedCoreError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

public struct SharedEngineLaunch: Sendable {
    public let executable: String
    public let arguments: [String]
}

public enum SharedCore {
    public static var apiVersion: UInt32 { tp_core_api_version() }

    public static func call(_ fields: [String: Any]) throws -> [String: Any] {
        var request = fields
        request["apiVersion"] = 1
        let data = try JSONSerialization.data(withJSONObject: request)
        return try data.withUnsafeBytes { bytes in
            guard let output = tp_core_call(bytes.bindMemory(to: UInt8.self).baseAddress, data.count) else {
                throw SharedCoreError(code: "coreUnavailable", message: "Shared core is unavailable.")
            }
            defer { tp_core_free(output) }
            let response = try JSONSerialization.jsonObject(with: Data(String(cString: output).utf8)) as? [String: Any]
            guard response?["ok"] as? Bool == true, let value = response?["value"] as? [String: Any] else {
                let error = response?["error"] as? [String: String]
                throw SharedCoreError(code: error?["code"] ?? "invalidResponse", message: error?["message"] ?? "Shared core returned an invalid response.")
            }
            return value
        }
    }

    public static func isValidEndpoint(host: String, port: Int) -> Bool {
        (try? call(["method": "validateEndpoint", "host": host, "port": port])) != nil
    }

    public static func validateConnection(_ connection: [String: Any]) throws {
        _ = try call(["method": "validateConnection", "connection": connection])
    }

    public static func engineLaunch(engine: String, runtime: String, script: String? = nil, modules: String? = nil) throws -> SharedEngineLaunch {
        var request: [String: Any] = ["method": "engineLaunch", "engine": engine, "runtime": runtime]
        if let modules { request["modules"] = modules }
        let value = try call(request)
        guard let executable = value["executable"] as? String, let arguments = value["arguments"] as? [String] else {
            throw SharedCoreError(code: "invalidResponse", message: "Invalid engine launch configuration.")
        }
        return SharedEngineLaunch(executable: executable, arguments: arguments)
    }
}

