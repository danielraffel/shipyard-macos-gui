import Foundation

/// Which config layer supplied the active profile (from `config profiles --json`
/// `active_source`). `.unknown` covers an older CLI that omits the field.
enum RoutingActiveSource: String, Decodable {
    case local
    case tracked
    case global
    case none
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RoutingActiveSource(rawValue: raw) ?? .unknown
    }
}

/// How the local overlay was resolved on the CLI side.
enum RoutingLocalOverlaySource: String, Decodable {
    case direct
    case worktreeFallback = "worktree_fallback"
    case none
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RoutingLocalOverlaySource(rawValue: raw) ?? .unknown
    }
}

/// One profile row from `shipyard config profiles --json`.
struct RoutingProfile: Decodable, Equatable, Identifiable {
    let name: String
    let active: Bool
    let targets: [String]
    let description: String?
    let focusPlatforms: [String]
    let advisoryPlatforms: [String]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, active, targets, description
        case focusPlatforms = "focus_platforms"
        case advisoryPlatforms = "advisory_platforms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description)
        focusPlatforms = try c.decodeIfPresent([String].self, forKey: .focusPlatforms) ?? []
        advisoryPlatforms = try c.decodeIfPresent([String].self, forKey: .advisoryPlatforms) ?? []
    }

    /// Description-first label (the proposal's UX rule). Falls back to a canonical
    /// plain-English label for the well-known profile names, else the name itself.
    var displayLabel: String {
        if let description, !description.isEmpty { return description }
        switch name {
        case "local": return "Just my Mac"
        case "normal": return "Mac + cloud"
        case "cloud": return "Everything on cloud"
        case "full": return "Mac + local VMs"
        default: return name
        }
    }
}

/// Decoded `config.profiles` envelope. New CLI fields are tolerated-absent so an
/// older shipyard still decodes (capability gate keys off `activeSource`).
struct RoutingProfilesSnapshot: Decodable, Equatable {
    let profiles: [RoutingProfile]
    let active: String?
    let activeSource: RoutingActiveSource
    let activePath: String?
    let localOverlaySource: RoutingLocalOverlaySource
    let localOverlayPath: String?
    let trackedConfigPath: String?

    enum CodingKeys: String, CodingKey {
        case profiles, active
        case activeSource = "active_source"
        case activePath = "active_path"
        case localOverlaySource = "local_overlay_source"
        case localOverlayPath = "local_overlay_path"
        case trackedConfigPath = "tracked_config_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([RoutingProfile].self, forKey: .profiles) ?? []
        active = try c.decodeIfPresent(String.self, forKey: .active)
        // Absent → `.unknown` is the old-CLI signal the capability gate watches for.
        activeSource = try c.decodeIfPresent(RoutingActiveSource.self, forKey: .activeSource) ?? .unknown
        activePath = try c.decodeIfPresent(String.self, forKey: .activePath)
        localOverlaySource =
            try c.decodeIfPresent(RoutingLocalOverlaySource.self, forKey: .localOverlaySource) ?? .unknown
        localOverlayPath = try c.decodeIfPresent(String.self, forKey: .localOverlayPath)
        trackedConfigPath = try c.decodeIfPresent(String.self, forKey: .trackedConfigPath)
    }

    /// New CLI = it reports an explicit active source. Used to gate writable routing.
    var cliReportsActiveSource: Bool { activeSource != .unknown }
}

/// Where a routing repository's checkout path came from.
enum RoutingRepositorySource: String, Codable, Equatable {
    case shipState
    case userOverride
}

/// A repo the Routing picker can target. `id` is STABLE per the proposal: a rooted
/// entry uses its absolute `repoRoot`; a no-root entry uses `"noroot:" + repo` and
/// keeps that id even after a checkout override is applied.
struct RoutingRepository: Identifiable, Equatable, Hashable {
    let id: String
    let repo: String
    let repoRoot: String?
    let source: RoutingRepositorySource

    static func rooted(repo: String, repoRoot: String) -> RoutingRepository {
        RoutingRepository(id: repoRoot, repo: repo, repoRoot: repoRoot, source: .shipState)
    }

    static func noRoot(repo: String, override: String?) -> RoutingRepository {
        RoutingRepository(
            id: "noroot:\(repo)",
            repo: repo,
            repoRoot: override,
            source: override == nil ? .shipState : .userOverride
        )
    }

    /// Display subtitle disambiguating multiple checkouts of the same slug.
    var pathSubtitle: String { repoRoot ?? "no checkout chosen" }
}

/// Per-repo routing UI state held by the store.
struct RoutingState: Equatable {
    var snapshot: RoutingProfilesSnapshot?
    var isLoading: Bool = false
    var isSaving: Bool = false
    var savingProfileName: String?
    var errorMessage: String?
}
