import Foundation

public enum AppVersion {
    /// Bump this before tagging a GitHub release (the tag should be `v` + this value).
    public static let current = "0.3.0"

    /// The version of the running app: the bundle's version when packaged, else `current`.
    public static var running: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? current
    }
}
