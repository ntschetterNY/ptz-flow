import Foundation

/// A GitHub release, as returned by `GET /repos/{owner}/{repo}/releases/latest`.
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let name: String?
    public let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
    }

    public var version: String { SemanticVersion.strip(tagName) }
}

public struct SemanticVersion: Comparable, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        let core = SemanticVersion.strip(string).split(separator: "-").first.map(String.init) ?? ""
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func strip(_ s: String) -> String {
        s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// Checks GitHub for a newer release. It never downloads or installs anything:
/// the app shows a notice with a direct link to the release page.
public struct UpdateChecker: Sendable {
    public let owner: String
    public let repo: String

    public init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    public var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases")! }

    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PTZFlow/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// The latest release if it is newer than `currentVersion`, else nil (also nil on any network error).
    public func availableUpdate(currentVersion: String) async -> ReleaseInfo? {
        guard let release = try? await latestRelease() else { return nil }
        return UpdateChecker.isNewer(release.version, than: currentVersion) ? release : nil
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = SemanticVersion(candidate), let b = SemanticVersion(current) else { return false }
        return b < a
    }
}
