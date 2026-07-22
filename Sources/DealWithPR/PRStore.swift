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

    // Private plumbing
    private let service = GitHubService()
    private var timer: Timer?
    private var knownReviewURLs: Set<String> = []
    private var hasBaseline = false
    private var knownMyDecisions: [String: String] = [:]
    private var hasMyBaseline = false
    private(set) var isRefreshing = false

    // MARK: - Derived views for the UI

    /// Your PRs with drafts on top, each group most-recently-updated first.
    var myPRsSorted: [PullRequest] {
        myPRs.sorted { a, b in
            if a.isDraft != b.isDraft { return a.isDraft && !b.isDraft }
            return a.updatedAt > b.updatedAt
        }
    }

    var humanReviews: [PullRequest] {
        reviewRequests.filter { !$0.authorIsBot }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var botReviews: [PullRequest] {
        reviewRequests.filter { $0.authorIsBot }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Badge count = human review requests awaiting you.
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
        for pr in myPRs { current[pr.url] = pr.reviewDecision?.rawValue ?? "none" }
        defer { knownMyDecisions = current }

        guard hasMyBaseline else { hasMyBaseline = true; return }
        guard notificationsEnabled else { return }

        for pr in myPRs {
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
