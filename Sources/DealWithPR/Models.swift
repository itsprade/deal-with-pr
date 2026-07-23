import Foundation

// MARK: - Domain model used by the UI

/// A single pull request, flattened from the GraphQL response into just what
/// the UI needs to display. Read-only — the app never mutates PRs.
struct PullRequest: Identifiable, Hashable, Sendable {
    let id: String        // the PR url — stable & unique
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let repo: String      // "owner/name"
    let updatedAt: Date
    let reviewDecision: ReviewDecision?
    let ciStatus: CIStatus?
    let authorLogin: String?
    let authorIsBot: Bool
    /// True when the ball is in your court: the most recent comment/review is by
    /// someone else, or it's a fresh review request with no activity yet. Only
    /// meaningful for review-requested PRs (false for your own authored PRs).
    let needsAttention: Bool
    /// Timestamp of the most recent comment/review, used for ordering.
    let lastActivityAt: Date?

    /// Just the repository name, e.g. "app-shell" from "tailor-platform/app-shell".
    var repoShort: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

enum ReviewDecision: String, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"

    var label: String {
        switch self {
        case .approved:         return "Approved"
        case .changesRequested: return "Changes"
        case .reviewRequired:   return "In review"
        }
    }
}

enum CIStatus: String, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
}

// MARK: - Stats (streak + merged counts)

/// Glanceable stats shown in the strip. Read-only, derived from GitHub data.
struct Stats: Sendable {
    let currentStreak: Int
    let mergedThisMonth: Int
    let mergedLast3: Int
    let mergedLast6: Int
    let mergedThisYear: Int
    let mergedLastYear: Int

    func merged(in range: StatsRange) -> Int {
        switch range {
        case .thisMonth: return mergedThisMonth
        case .last3:     return mergedLast3
        case .last6:     return mergedLast6
        case .thisYear:  return mergedThisYear
        case .lastYear:  return mergedLastYear
        }
    }
}

enum StatsRange: String, CaseIterable, Sendable {
    case thisMonth = "This month"
    case last3 = "Last 3 months"
    case last6 = "Last 6 months"
    case thisYear = "This year"
    case lastYear = "Last year"

    /// Next range in the cycle (wraps around).
    var next: StatsRange {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// The full year contribution calendar (GitHub's green-squares grid), flattened
/// for rendering. Each week is 7 day-slots keyed by weekday (0 = Sunday), with
/// `nil` for the partial first/last weeks.
struct ContributionGraph: Sendable {
    struct Day: Sendable, Identifiable {
        let id: String        // the date
        let date: String
        let count: Int
        let level: Int        // 0 (none) … 4 (most)
    }
    let weeks: [[Day?]]       // columns; each is 7 rows (Sun→Sat)
    let total: Int

    /// Convert a GitHub `contributionLevel` string to a 0…4 intensity.
    static func level(from raw: String) -> Int {
        switch raw {
        case "FIRST_QUARTILE":  return 1
        case "SECOND_QUARTILE": return 2
        case "THIRD_QUARTILE":  return 3
        case "FOURTH_QUARTILE": return 4
        default:                return 0   // NONE
        }
    }
}

// MARK: - Raw GraphQL decoding

/// Mirrors the shape returned by the single combined `gh api graphql` call.
struct GraphQLResponse: Decodable {
    let data: DataField

    struct DataField: Decodable {
        let viewer: Viewer
        let search: Search
        let month: Count
        let last3: Count
        let last6: Count
        let thisYear: Count
        let lastYear: Count
    }
    struct Viewer: Decodable {
        let login: String
        let pullRequests: NodeList
        let contributionsCollection: Contributions
    }
    struct Contributions: Decodable {
        let contributionCalendar: ContributionCalendar
    }
    struct ContributionCalendar: Decodable {
        let totalContributions: Int
        let weeks: [Week]
        struct Week: Decodable {
            let contributionDays: [Day]
            struct Day: Decodable {
                let date: String
                let weekday: Int
                let contributionCount: Int
                let contributionLevel: String
            }
        }
    }
    struct Count: Decodable {
        let issueCount: Int
    }
    struct Search: Decodable {
        let nodes: [RawPR]
    }
    struct NodeList: Decodable {
        let nodes: [RawPR]
    }
}

struct RawPR: Decodable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let updatedAt: Date
    let reviewDecision: String?
    let repository: Repo
    let author: Author?
    let commits: Commits?
    let timelineItems: TimelineItems?

    struct Repo: Decodable {
        let nameWithOwner: String
    }
    /// The most recent comment / review / commit on the PR, used to decide whose
    /// court the ball is in. The three union members expose different shapes, so
    /// the node carries them all optionally and exposes unified accessors.
    struct TimelineItems: Decodable {
        let nodes: [Node]
        struct Node: Decodable {
            let typeName: String
            let author: TLAuthor?      // IssueComment / PullRequestReview
            let createdAt: Date?       // IssueComment / PullRequestReview
            let commit: TLCommit?      // PullRequestCommit
            enum CodingKeys: String, CodingKey {
                case typeName = "__typename"
                case author, createdAt, commit
            }
            struct TLAuthor: Decodable { let login: String }
            struct TLCommit: Decodable {
                let committedDate: Date?
                let author: CommitAuthor?
                struct CommitAuthor: Decodable { let user: TLAuthor? }
            }

            /// Login of whoever produced this activity (comment/review author, or
            /// the commit's GitHub user), if resolvable.
            var actorLogin: String? { author?.login ?? commit?.author?.user?.login }
            /// When this activity happened.
            var occurredAt: Date? { createdAt ?? commit?.committedDate }
        }
    }
    struct Author: Decodable {
        let login: String
        let typeName: String
        enum CodingKeys: String, CodingKey {
            case login
            case typeName = "__typename"
        }
    }
    struct Commits: Decodable {
        let nodes: [CommitNode]
        struct CommitNode: Decodable {
            let commit: Commit
            struct Commit: Decodable {
                let statusCheckRollup: Rollup?
                struct Rollup: Decodable { let state: String }
            }
        }
    }

    /// Some bots report `__typename == "Bot"`, others come through as regular
    /// users with a `[bot]` login suffix (or the bare renovate/dependabot name).
    var isBot: Bool {
        guard let author else { return false }
        let login = author.login.lowercased()
        return author.typeName == "Bot"
            || login.hasSuffix("[bot]")
            || login == "renovate"
            || login == "dependabot"
    }

    var ciStatus: CIStatus? {
        guard let state = commits?.nodes.first?.commit.statusCheckRollup?.state else { return nil }
        return CIStatus(rawValue: state)
    }

    /// Convert to the flattened UI model. `viewerLogin` is supplied only for the
    /// review set so we can compute whether the ball is in the viewer's court.
    func toPullRequest(viewerLogin: String? = nil) -> PullRequest {
        // Ball is in your court when the most recent activity (comment, review,
        // or commit) is by someone other than you — or there's none yet (a fresh
        // request). Unresolvable actor → treat as "someone else". timelineItems
        // is nil only if not queried (shouldn't happen; safe default false).
        let lastActivity = timelineItems?.nodes.last
        let needsAttention: Bool
        if timelineItems == nil {
            needsAttention = false
        } else if let actor = lastActivity?.actorLogin {
            needsAttention = actor.caseInsensitiveCompare(viewerLogin ?? "") != .orderedSame
        } else {
            needsAttention = true
        }
        return PullRequest(
            id: url,
            number: number,
            title: title,
            url: url,
            isDraft: isDraft,
            repo: repository.nameWithOwner,
            updatedAt: updatedAt,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            ciStatus: ciStatus,
            authorLogin: author?.login,
            authorIsBot: isBot,
            needsAttention: needsAttention,
            lastActivityAt: lastActivity?.occurredAt
        )
    }
}
