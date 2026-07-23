import Foundation
import Observation
import UserNotifications

/// Observable state for the whole app: the two PR lists, load state, and the
/// refresh timer. Also fires a native notification when a genuinely new review
/// request appears.
@MainActor
@Observable
final class PRStore {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(GitHubError)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.loaded, .loaded):
                return true
            case let (.error(a), .error(b)):
                return a.localizedDescription == b.localizedDescription
            default:
                return false
            }
        }
    }

    // Public, observed state
    private(set) var myPRs: [PullRequest] = []
    private(set) var reviewRequests: [PullRequest] = []
    private(set) var stats: Stats?
    private(set) var graph: ContributionGraph?
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    // User preferences (persisted in UserDefaults)
    var statsRange: StatsRange = StatsRange(rawValue: UserDefaults.standard.string(forKey: "dwpr.statsRange") ?? "") ?? .thisMonth {
        didSet { UserDefaults.standard.set(statsRange.rawValue, forKey: "dwpr.statsRange") }
    }
    var refreshMinutes: Int = {
        let stored = UserDefaults.standard.integer(forKey: "dwpr.refreshMinutes")
        return stored == 0 ? 5 : stored
    }() {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: "dwpr.refreshMinutes")
            scheduleTimer()
        }
    }

    // Notification preferences (default on; persisted)
    var notificationsEnabled: Bool = (UserDefaults.standard.object(forKey: "dwpr.notif.enabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "dwpr.notif.enabled") }
    }
    var notifyReviewRequested: Bool = (UserDefaults.standard.object(forKey: "dwpr.notif.review") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(notifyReviewRequested, forKey: "dwpr.notif.review") }
    }
    var notifyApproved: Bool = (UserDefaults.standard.object(forKey: "dwpr.notif.approved") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(notifyApproved, forKey: "dwpr.notif.approved") }
    }
    var notifyChangesRequested: Bool = (UserDefaults.standard.object(forKey: "dwpr.notif.changes") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(notifyChangesRequested, forKey: "dwpr.notif.changes") }
    }

    /// When false, all repositories are shown (default). When true, only repos
    /// in `repoFilter` are shown — which may be empty, meaning "show none".
    /// Streaks/stats are global and unaffected either way.
    var repoFilterActive: Bool = UserDefaults.standard.bool(forKey: "dwpr.repoFilterActive") {
        didSet {
            UserDefaults.standard.set(repoFilterActive, forKey: "dwpr.repoFilterActive")
            resetNotificationBaseline()
        }
    }
    /// The explicit allowlist of repositories ("owner/name") when active.
    var repoFilter: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dwpr.repoFilter") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(repoFilter), forKey: "dwpr.repoFilter")
            resetNotificationBaseline()
        }
    }

    /// Re-baseline so changing the filter doesn't fire a burst of notifications
    /// for repos that were simply hidden before.
    private func resetNotificationBaseline() {
        hasBaseline = false
        hasMyBaseline = false
    }

    // Private plumbing
    private let service = GitHubService()
    private var timer: Timer?
    private var knownReviewURLs: Set<String> = []
    private var hasBaseline = false
    private var knownMyDecisions: [String: String] = [:]
    private var hasMyBaseline = false
    private(set) var isRefreshing = false

    // MARK: - Repository filter

    /// True when the PR belongs to a repo the user wants to see (or no filter).
    private func passesFilter(_ pr: PullRequest) -> Bool {
        !repoFilterActive || repoFilter.contains(pr.repo)
    }

    /// Every repository seen across your PRs and review requests (sorted).
    var allRepos: [String] {
        Set((myPRs + reviewRequests).map(\.repo)).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Whether a repo is currently shown.
    func isRepoIncluded(_ repo: String) -> Bool {
        !repoFilterActive || repoFilter.contains(repo)
    }

    /// Toggle a repo's inclusion. If the filter was inactive, activate it seeded
    /// with everything so unticking one repo just hides that one. If the result
    /// then covers every known repo, deactivate again (show all, incl. future).
    func toggleRepo(_ repo: String) {
        if !repoFilterActive {
            repoFilterActive = true
            repoFilter = Set(allRepos)
        }
        if repoFilter.contains(repo) { repoFilter.remove(repo) } else { repoFilter.insert(repo) }
        if repoFilter == Set(allRepos) { repoFilterActive = false }
    }

    /// Show every repository, including ones that appear in the future.
    func selectAllRepos() {
        repoFilter = []
        repoFilterActive = false
    }

    /// Show none until the user picks specific repos.
    func unselectAllRepos() {
        repoFilter = []
        repoFilterActive = true
    }

    // MARK: - Derived views for the UI

    /// Your PRs, most-recently-updated first (no draft grouping), repo-filtered.
    var myPRsSorted: [PullRequest] {
        myPRs.filter(passesFilter).sorted { $0.updatedAt > $1.updatedAt }
    }

    var humanReviews: [PullRequest] {
        reviewRequests.filter { !$0.authorIsBot && passesFilter($0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var botReviews: [PullRequest] {
        reviewRequests.filter { $0.authorIsBot && passesFilter($0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Badge count = human review requests awaiting you (repo-filtered).
    var reviewCount: Int { humanReviews.count }

    // MARK: - Lifecycle

    func start() {
        Task { await requestNotificationAuthorization() }
        refresh()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Only show the full-screen spinner on the very first load.
        if myPRs.isEmpty && reviewRequests.isEmpty {
            loadState = .loading
        }

        Task {
            defer { isRefreshing = false }
            do {
                let result = try await service.fetch()
                myPRs = result.mine
                reviewRequests = result.review
                stats = result.stats
                graph = result.graph
                lastUpdated = Date()
                loadState = .loaded
                detectNewReviewRequests()
                detectMyPRUpdates()
            } catch let error as GitHubError {
                loadState = .error(error)
            } catch {
                loadState = .error(.commandFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Compare current human review requests to the previous snapshot and
    /// notify for URLs we haven't seen before. Skips the first load so we
    /// don't fire a burst of notifications on launch.
    private func detectNewReviewRequests() {
        let currentURLs = Set(humanReviews.map(\.url))

        guard hasBaseline else {
            knownReviewURLs = currentURLs
            hasBaseline = true
            return
        }

        let newURLs = currentURLs.subtracting(knownReviewURLs)
        knownReviewURLs = currentURLs

        guard !newURLs.isEmpty else { return }
        guard notificationsEnabled, notifyReviewRequested else { return }
        let newPRs = humanReviews.filter { newURLs.contains($0.url) }
        sendNotification(for: newPRs)
    }

    private func sendNotification(for prs: [PullRequest]) {
        guard !prs.isEmpty else { return }
        if prs.count == 1, let pr = prs.first {
            postNotification(title: "New review request",
                             body: "\(pr.repoShort) #\(pr.number) · \(pr.title)",
                             url: pr.url)
        } else {
            postNotification(title: "\(prs.count) new review requests",
                             body: prs.prefix(3).map { "\($0.repoShort) #\($0.number)" }.joined(separator: ", "),
                             url: "https://github.com/pulls/review-requested")
        }
    }

    /// Notify when one of *your* PRs changes to approved or changes-requested.
    private func detectMyPRUpdates() {
        var current: [String: String] = [:]
        for pr in myPRsSorted { current[pr.url] = pr.reviewDecision?.rawValue ?? "none" }
        defer { knownMyDecisions = current }

        guard hasMyBaseline else { hasMyBaseline = true; return }
        guard notificationsEnabled else { return }

        for pr in myPRsSorted {
            guard let old = knownMyDecisions[pr.url] else { continue }   // newly seen — skip
            let new = pr.reviewDecision?.rawValue ?? "none"
            guard old != new else { continue }
            switch pr.reviewDecision {
            case .approved where notifyApproved:
                postNotification(title: "Pull request approved ✅",
                                 body: "\(pr.repoShort) #\(pr.number) · \(pr.title)",
                                 url: pr.url)
            case .changesRequested where notifyChangesRequested:
                postNotification(title: "Changes requested",
                                 body: "\(pr.repoShort) #\(pr.number) · \(pr.title)",
                                 url: pr.url)
            default:
                break
            }
        }
    }

    private func postNotification(title: String, body: String, url: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
