import Foundation

/// Switches Ecamm Live scenes through Ecamm's AppleScript support
/// (Ecamm > Preferences > Remote Control must allow AppleScript; macOS asks once for Automation permission).
///
/// The exact AppleScript wording is taken from Ecamm's "Automating Ecamm" help article
/// (`set scene name "..."`). Verify it against Ecamm's scripting dictionary
/// (Script Editor > File > Open Dictionary > Ecamm Live) on the church Mac.
enum EcammBridge {
    /// Returns nil on success, or an error description.
    @MainActor
    static func switchScene(named name: String) -> String? {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Ecamm Live\" to set scene name \"\(escaped)\""
        guard let script = NSAppleScript(source: source) else { return "Could not build the AppleScript" }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorMessage] as? String) ?? error.description
        }
        return nil
    }
}
