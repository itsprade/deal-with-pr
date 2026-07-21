import Foundation

/// Errors surfaced to the UI with friendly, actionable messages.
enum GitHubError: LocalizedError {
    case ghNotFound
    case notAuthenticated
    case commandFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI (gh) not found"
        case .notAuthenticated:
            return "Not signed in to GitHub"
        case .commandFailed(let msg):
            return msg.isEmpty ? "gh command failed" : msg
        case .decodingFailed(let msg):
            return "Couldn't read GitHub's response: \(msg)"
        }
    }

    var hint: String {
        switch self {
        case .ghNotFound:
            return "Install it with  brew install gh"
        case .notAuthenticated:
            return "Run  gh auth login  in Terminal, then refresh."
        case .commandFailed:
            return "Check your network connection and try Refresh."
        case .decodingFailed:
            return "Try Refresh. If it persists, update gh."
        }
    }

    /// True for first-run setup problems (missing CLI / not signed in) that
    /// warrant the onboarding screen rather than a generic error.
    var isSetupIssue: Bool {
        switch self {
        case .ghNotFound, .notAuthenticated: return true
        default: return false
        }
    }

    /// Whether the `gh` CLI itself is present (used to tick off setup steps).
    var ghInstalled: Bool {
        switch self {
        case .ghNotFound: return false
        default: return true
        }
    }
}

/// Stateless wrapper around the `gh` CLI. One combined GraphQL call returns
/// both lists plus review-decision and CI-status data.
struct GitHubService: Sendable {

    struct Result: Sendable {
        let mine: [PullRequest]
        let review: [PullRequest]
        let stats: Stats
        let graph: ContributionGraph
    }

    /// Builds the combined query. Merged-PR date thresholds are computed here so
    /// the strip's ranges (month / 3mo / 6mo / year) come back in one round trip.
    private static func buildQuery() -> String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let year = cal.component(.year, from: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let sixMonthsAgo = cal.date(byAdding: .month, value: -6, to: now) ?? now
        let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let lastYearStart = cal.date(from: DateComponents(year: year - 1, month: 1, day: 1)) ?? now
        let lastYearEnd = cal.date(from: DateComponents(year: year - 1, month: 12, day: 31)) ?? now

        return """
        {
          viewer {
            pullRequests(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number
                title
                url
                isDraft
                updatedAt
                reviewDecision
                repository { nameWithOwner }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
            contributionsCollection {
              contributionCalendar {
                totalContributions
                weeks { contributionDays { date weekday contributionCount contributionLevel } }
              }
            }
          }
          search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 50) {
            nodes {
              ... on PullRequest {
                number
                title
                url
                isDraft
                updatedAt
                reviewDecision
                author { login __typename }
                repository { nameWithOwner }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
          month:    search(query: "is:pr author:@me is:merged merged:>=\(isoDate(startOfMonth))", type: ISSUE) { issueCount }
          last3:    search(query: "is:pr author:@me is:merged merged:>=\(isoDate(threeMonthsAgo))", type: ISSUE) { issueCount }
          last6:    search(query: "is:pr author:@me is:merged merged:>=\(isoDate(sixMonthsAgo))", type: ISSUE) { issueCount }
          thisYear: search(query: "is:pr author:@me is:merged merged:>=\(isoDate(startOfYear))", type: ISSUE) { issueCount }
          lastYear: search(query: "is:pr author:@me is:merged merged:\(isoDate(lastYearStart))..\(isoDate(lastYearEnd))", type: ISSUE) { issueCount }
        }
        """
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Current streak = consecutive most-recent days with ≥1 contribution.
    /// Today is ignored if it has 0 so far, matching GitHub's behaviour of not
    /// breaking the streak until the day is actually over.
    private static func computeStreak(_ calendar: GraphQLResponse.ContributionCalendar) -> Int {
        var days = calendar.weeks
            .flatMap { $0.contributionDays }
            .sorted { $0.date < $1.date }
        if let last = days.last, last.contributionCount == 0 {
            days.removeLast()
        }
        var streak = 0
        for day in days.reversed() {
            if day.contributionCount > 0 { streak += 1 } else { break }
        }
        return streak
    }

    /// Reshape the calendar into columns of 7 weekday-aligned slots for rendering.
    private static func buildGraph(_ calendar: GraphQLResponse.ContributionCalendar) -> ContributionGraph {
        let weeks: [[ContributionGraph.Day?]] = calendar.weeks.map { week in
            var slots = [ContributionGraph.Day?](repeating: nil, count: 7)
            for day in week.contributionDays where (0...6).contains(day.weekday) {
                slots[day.weekday] = ContributionGraph.Day(
                    id: day.date,
                    date: day.date,
                    count: day.contributionCount,
                    level: ContributionGraph.level(from: day.contributionLevel)
                )
            }
            return slots
        }
        return ContributionGraph(weeks: weeks, total: calendar.totalContributions)
    }

    // MARK: - Public API

    func fetch() async throws -> Result {
        // Run the blocking Process off the main actor.
        try await Task.detached(priority: .userInitiated) {
            try Self.run()
        }.value
    }

    // MARK: - Implementation

    private static func run() throws -> Result {
        guard let gh = locateGH() else { throw GitHubError.ghNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "-f", "query=\(buildQuery())"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitHubError.commandFailed(error.localizedDescription)
        }

        // Read stdout to EOF first (completes when the process exits and closes
        // the pipe), then wait — this ordering avoids a full-buffer deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? ""
            let lowered = message.lowercased()
            if lowered.contains("authentication")
                || lowered.contains("gh auth login")
                || lowered.contains("http 401")
                || lowered.contains("not logged") {
                throw GitHubError.notAuthenticated
            }
            throw GitHubError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response: GraphQLResponse
        do {
            response = try decoder.decode(GraphQLResponse.self, from: outData)
        } catch {
            let raw = String(data: outData, encoding: .utf8) ?? ""
            throw GitHubError.decodingFailed(String(raw.prefix(200)))
        }

        let mine = response.data.viewer.pullRequests.nodes.map { $0.toPullRequest() }
        let review = response.data.search.nodes.map { $0.toPullRequest() }
        let stats = Stats(
            currentStreak: computeStreak(response.data.viewer.contributionsCollection.contributionCalendar),
            mergedThisMonth: response.data.month.issueCount,
            mergedLast3: response.data.last3.issueCount,
            mergedLast6: response.data.last6.issueCount,
            mergedThisYear: response.data.thisYear.issueCount,
            mergedLastYear: response.data.lastYear.issueCount
        )
        let graph = buildGraph(response.data.viewer.contributionsCollection.contributionCalendar)
        return Result(mine: mine, review: review, stats: stats, graph: graph)
    }

    /// Find the `gh` binary. Common Homebrew / system locations first, then
    /// fall back to a login-shell `which` so PATH customizations are honoured.
    private static func locateGH() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",   // Apple Silicon Homebrew
            "/usr/local/bin/gh",      // Intel Homebrew
            "/usr/bin/gh"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return whichViaShell()
    }

    private static func whichViaShell() -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-l", "-c", "which gh"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = Pipe()
        do {
            try shell.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        guard shell.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }
}
