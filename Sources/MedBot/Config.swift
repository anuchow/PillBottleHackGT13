import Foundation

/// Settings from environment variables, falling back to a `.env` file. Placeholder values ("your_...") count as unset.
public struct Config: Sendable {
    private let values: [String: String]

    public static func load(dotEnvPath: String = ".env") -> Config {
        var values: [String: String] = [:]
        if let file = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) {
            for line in file.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        values.merge(ProcessInfo.processInfo.environment) { _, environment in environment }
        return Config(values: values)
    }

    public subscript(key: String) -> String? {
        guard let value = values[key], !value.isEmpty, !value.hasPrefix("your_") else { return nil }
        return value
    }
}
