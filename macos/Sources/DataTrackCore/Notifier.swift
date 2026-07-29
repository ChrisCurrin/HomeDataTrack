import Foundation

/// Delivers user-visible alerts.
///
/// Uses `osascript`'s `display notification` rather than `UNUserNotificationCenter`
/// because the sampler is expected to run as a launchd agent with no app bundle,
/// and `UNUserNotificationCenter` requires a bundle identifier to register.
public enum Notifier {
    public static func notify(title: String, subtitle: String? = nil, message: String) {
        var script = "display notification \(escape(message)) with title \(escape(title))"
        if let subtitle {
            script += " subtitle \(escape(subtitle))"
        }
        _ = try? Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)
    }

    /// Wraps a string as an AppleScript literal.
    ///
    /// Escaping matters here: network names are attacker-adjacent input. An SSID
    /// containing a quote would otherwise terminate the literal and let the rest
    /// of the name run as AppleScript.
    public static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n", "\r": escaped += " "
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
