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
    var statsRange: StatsRange = .thisMonth
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    // Private plumbing
    private let service = GitHubService()
    private var timer: Timer?
    private var knownReviewURLs: Set<String> = []
    private var hasBaseline = false
    private(set) var isRefreshing = false

    private let refreshInterval: TimeInterval = 300 // 5 minutes

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
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
        let newPRs = humanReviews.filter { newURLs.contains($0.url) }
        sendNotification(for: newPRs)
    }

    private func sendNotification(for prs: [PullRequest]) {
        guard !prs.isEmpty else { return }
        let content = UNMutableNotificationContent()

        if prs.count == 1, let pr = prs.first {
            content.title = "New review request"
            content.body = "\(pr.repoShort) #\(pr.number) · \(pr.title)"
        } else {
            content.title = "\(prs.count) new review requests"
            content.body = prs.prefix(3).map { "\($0.repoShort) #\($0.number)" }.joined(separator: ", ")
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
