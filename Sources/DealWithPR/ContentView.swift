import SwiftUI
import AppKit
import Sparkle

// Layout "3a": one card — green liquid-glass cover (streak + heatmap + pills),
// then segmented tabs (Your PRs / People / Deps) + density toggle, then the list.

@MainActor
struct ContentView: View {
    @Bindable var store: PRStore

    private enum MainTab: Int { case yours, people, deps }
    @State private var tab: MainTab = .yours
    @State private var slideForward = true
    @Namespace private var rowNS
    @Namespace private var hoverNS
    @State private var hoveredID: PullRequest.ID?
    @AppStorage("dwpr.themeIndex") private var themeIndex = 0
    // Shared with the footer toggle and Settings.
    @AppStorage("dwpr.compact") private var compact = false
    @AppStorage("dwpr.showStreak") private var showStreak = true

    private func setHover(_ id: PullRequest.ID, _ on: Bool) {
        withAnimation(.snappy(duration: 0.13)) {
            if on { hoveredID = id }
            else if hoveredID == id { hoveredID = nil }
        }
    }

    private var theme: AppTheme { appThemes[min(max(themeIndex, 0), appThemes.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer   // always-visible bottom bar
        }
        .frame(width: 460)
        .background {
            // The glass itself is the panel's NSGlassEffectView behind this view.
            // Only a very light, bottom-weighted tint here so list/footer text
            // stays readable over the glass without killing the transparency.
            // Clipped to the glass radius so the tint doesn't square off the corners.
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous))
        }
        .task { store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .loading where store.stats == nil:
            LoadingView()
        case .error(let error) where error.isSetupIssue:
            SetupStateView(error: error) { store.refresh() }
        case .error(let error):
            ErrorStateView(error: error) { store.refresh() }
        default:
            VStack(spacing: 0) {
                CoverView(store: store, theme: theme, showStreak: showStreak)
                tabsBar
                listArea
                    .id(tab)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading),
                        removal: .move(edge: slideForward ? .leading : .trailing)
                    ))
                    .clipped()
            }
            // Full hero wash when the streak section is shown; a slim colored
            // band behind the header otherwise (never plain glass at the top).
            .background {
                if showStreak {
                    CoverAtmosphere(theme: theme)
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: theme.cover[0], location: 0.00),
                            .init(color: theme.cover[1], location: 0.55),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // Match the hero gradient's height when streaks are shown.
                    .frame(height: 180)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: - Selected list

    private var currentList: [PullRequest] {
        switch tab {
        case .yours:  return store.myPRsSorted
        case .people: return store.humanReviews
        case .deps:   return store.botReviews
        }
    }

    // MARK: - Tabs + density

    private var tabsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PR that needs your attention")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.leading, 2)

            HStack(alignment: .top, spacing: 10) {
                statCard("Your PR's", store.myPRsSorted.count, .yours)
                statCard("From People", store.humanReviews.count, .people)
                statCard("From Bots", store.botReviews.count, .deps)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Stat card that doubles as the tab selector: big count + label, with a
    /// highlighted border/fill when active.
    private func statCard(_ label: String, _ count: Int, _ value: MainTab) -> some View {
        let active = tab == value
        return Button {
            slideForward = value.rawValue >= tab.rawValue
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { tab = value }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(active ? 0.75 : 0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.35 : 0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: active)
    }

    // MARK: - List

    // Preferred list height; shrinks (and scrolls) when the panel is height-
    // capped on a short screen, so the footer is never clipped.
    private let listHeight: CGFloat = 348

    @ViewBuilder
    private var listArea: some View {
        if currentList.isEmpty {
            EmptyStateView(tab: emptyKind)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140, idealHeight: listHeight, maxHeight: listHeight)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                    ForEach(currentList) { pr in
                        if compact {
                            CompactRow(
                                pr: pr, ns: rowNS,
                                hovered: hoveredID == pr.id, hoverNS: hoverNS,
                                setHovered: { setHover(pr.id, $0) }
                            )
                        } else {
                            DetailRow(
                                pr: pr, showAuthor: tab != .yours, ns: rowNS,
                                hovered: hoveredID == pr.id, hoverNS: hoverNS,
                                setHovered: { setHover(pr.id, $0) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .overlay(ThinScroller().allowsHitTesting(false))
            }
            .scrollContentBackground(.hidden)   // let the panel's glass show through
            .scrollIndicators(.visible)
            .frame(minHeight: 140, idealHeight: listHeight, maxHeight: listHeight)
        }
    }

    private var emptyKind: EmptyStateView.Kind {
        switch tab {
        case .yours:  return .yours
        case .people: return .people
        case .deps:   return .deps
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(store.reviewCount) awaiting review")
            Spacer()
            // Compact / detailed row density
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { compact.toggle() }
            } label: {
                Image(systemName: compact ? "rectangle.grid.1x2" : "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle compact / detailed rows")

            // Quick theme cycle
            Circle()
                .fill(LinearGradient(
                    colors: theme.cover,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .contentShape(Circle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        themeIndex = (themeIndex + 1) % appThemes.count
                    }
                }
                .help("Theme: \(theme.name) — click to cycle")

            Button {
                NotificationCenter.default.post(name: .dwprOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .help("Quit Deal with PR")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.white.opacity(0.8))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }
}

/// Forces the enclosing NSScrollView to a thin, floating overlay scroller so the
/// bar never eats layout width — regardless of the user's "Show scroll bars"
/// system setting.
private struct ThinScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            var candidate: NSView? = view
            while let current = candidate, !(current is NSScrollView) {
                candidate = current.superview
            }
            if let scrollView = candidate as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.hasHorizontalScroller = false
                scrollView.verticalScroller?.controlSize = .mini
                scrollView.drawsBackground = false
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Cover (green liquid-glass hero)

// MARK: - Settings

@MainActor
struct SettingsView: View {
    @Bindable var store: PRStore
    let updater: SPUUpdater
    @AppStorage("dwpr.themeIndex") private var themeIndex = 0
    @AppStorage("dwpr.compact") private var compact = false
    @AppStorage("dwpr.showStreak") private var showStreak = true

    private let refreshOptions = [1, 2, 5, 15, 30, 60]

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: mark, then title, then version — stacked & centered
            VStack(spacing: 8) {
                AppLogo(size: 40)
                Text("Deal with PR Settings")
                    .font(.system(size: 16, weight: .bold))
                Text("v\(currentVersion)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)

            section("THEME") {
                HStack(spacing: 10) {
                    ForEach(appThemes) { swatch($0) }
                }
                .frame(maxWidth: .infinity)
            }

            section("GENERAL") {
                VStack(spacing: 12) {
                    toggleRow("Show streak & stats", $showStreak)
                    Divider()
                    settingRow("Merged total shows") {
                        Picker("", selection: $store.statsRange) {
                            ForEach(StatsRange.allCases, id: \.self) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .disabled(!showStreak)
                    .opacity(showStreak ? 1 : 0.3)
                    Divider()
                    toggleRow("Compact rows", $compact)
                    Divider()
                    settingRow("Refresh every") {
                        Picker("", selection: $store.refreshMinutes) {
                            ForEach(refreshOptions, id: \.self) { m in
                                Text(m < 60 ? "\(m) min" : "1 hour").tag(m)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            section("REPOSITORIES") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.repoFilterActive
                             ? "Showing \(store.allRepos.filter(store.isRepoIncluded).count) of \(store.allRepos.count)"
                             : "Showing all repositories")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        // One button that flips between select-all / unselect-all.
                        Button(store.repoFilterActive ? "Select all" : "Unselect all") {
                            if store.repoFilterActive { store.selectAllRepos() }
                            else { store.unselectAllRepos() }
                        }
                        .controlSize(.small)
                    }

                    if store.allRepos.isEmpty {
                        Text("No repositories yet — open the popover and refresh.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(store.allRepos, id: \.self) { repo in
                                    repoRow(repo)
                                }
                            }
                            .padding(.trailing, 12)   // keep rows clear of the scroll bar
                        }
                        .frame(maxHeight: 168)
                    }
                }
            }

            section("NOTIFICATIONS") {
                VStack(spacing: 11) {
                    toggleRow("Enable notifications", $store.notificationsEnabled)
                    Divider()
                    toggleRow("Review requested", $store.notifyReviewRequested)
                        .disabled(!store.notificationsEnabled)
                        .opacity(store.notificationsEnabled ? 1 : 0.3)
                    toggleRow("PR approved", $store.notifyApproved)
                        .disabled(!store.notificationsEnabled)
                        .opacity(store.notificationsEnabled ? 1 : 0.3)
                    toggleRow("Changes requested", $store.notifyChangesRequested)
                        .disabled(!store.notificationsEnabled)
                        .opacity(store.notificationsEnabled ? 1 : 0.3)
                }
            }

            section("UPDATES") {
                settingRow("App updates") {
                    Button("Check for Updates") { updater.checkForUpdates() }
                        .controlSize(.small)
                }
            }

            credit
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
    }

    /// A titled section: small-caps label above a rounded card.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(title)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func settingRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            control()
        }
    }

    /// One repository row: a leading checkbox + name + owner. The whole row is
    /// clickable to toggle inclusion.
    private func repoRow(_ repo: String) -> some View {
        let parts = repo.split(separator: "/", maxSplits: 1)
        let name = parts.last.map(String.init) ?? repo
        let owner = parts.count > 1 ? String(parts[0]) : ""
        let included = store.isRepoIncluded(repo)
        return Button {
            store.toggleRepo(repo)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: included ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    if !owner.isEmpty {
                        Text(owner).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ t: AppTheme) -> some View {
        Circle()
            .fill(LinearGradient(colors: [t.heat[0], t.cover[0]], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 16, height: 16)
            .overlay {
                if themeIndex == t.id {
                    Circle().stroke(Color.white, lineWidth: 2).padding(-3)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) { themeIndex = t.id }
            }
            .help(t.name)
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private var credit: some View {
        (Text("Made by ").foregroundColor(.secondary) + Text("@itsprade").foregroundColor(.primary).bold())
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { open("https://itsprade.com/") }
            .help("itsprade.com")
            .padding(.bottom, 8)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
private struct CoverView: View {
    let store: PRStore
    let theme: AppTheme
    var showStreak: Bool = true
    @State private var spinning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Deal with PR")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 5) {
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(spinning ? 360 : 0), anchor: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(
                        spinning ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default,
                        value: spinning
                    )
                    .onChange(of: store.isRefreshing) { _, refreshing in
                        spinning = refreshing
                    }
                    .disabled(store.isRefreshing)
                    .help("Refresh now")
                    Text(updatedText)
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.bottom, showStreak ? 14 : 0)

            if showStreak {
                HStack(alignment: .lastTextBaseline) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hex: "ffd23f"), Color(hex: "ff7a18"), Color(hex: "ff2d20")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("\(streakValue) \(streakValue == 1 ? "day" : "days")")
                            .font(.system(size: 34, weight: .bold))
                            .tracking(-1)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("streak")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()

                    HStack(spacing: 7) {
                        Text("\(store.stats?.merged(in: store.statsRange) ?? 0) merged")
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("•")
                            .foregroundStyle(.white.opacity(0.4))
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                store.statsRange = store.statsRange.next
                            }
                        } label: {
                            Text(store.statsRange.rawValue)
                                .foregroundStyle(.white.opacity(0.7))
                                .contentTransition(.opacity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to change the time range")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
            }

            if showStreak, let graph = store.graph {
                CoverHeatmap(graph: graph, theme: theme)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var streakValue: Int { store.stats?.currentStreak ?? 0 }

    private var updatedText: String {
        guard let updated = store.lastUpdated else { return "Updating…" }
        return "Updated \(RelativeTime.string(from: updated))"
    }
}

/// The liquid-glass backdrop. Used as the full background of the content area,
/// so the themed gradient runs from a strong hero at the top all the way to the
/// bottom of the window, easing down through many stops.
private struct CoverAtmosphere: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            // No material here — the window's behind-window glass shows through.
            // Just the themed colour wash for the hero, fading into the glass.
            // Colour stops are compressed into the hero region so the full
            // gradient spreads evenly across the top (not single-colour up top).
            LinearGradient(
                stops: [
                    .init(color: theme.cover[0], location: 0.00),
                    .init(color: mix(theme.cover[0], theme.cover[1]), location: 0.14),
                    .init(color: theme.cover[1], location: 0.28),
                    .init(color: mix(theme.cover[1], theme.cover[2]), location: 0.42),
                    .init(color: theme.cover[2], location: 0.55),
                    .init(color: theme.cover[2], location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.95)
            RadialGradient(
                colors: [Color.white.opacity(0.08), .clear],
                center: .top,
                startRadius: 4,
                endRadius: 240
            )
        }
        .mask(
            // Full colour through the hero, then a long, progressive alpha ramp
            // so the wash dissolves smoothly into the behind-window glass instead
            // of ending on a hard edge.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.00),
                    .init(color: .black, location: 0.30),
                    .init(color: .black.opacity(0.85), location: 0.42),
                    .init(color: .black.opacity(0.55), location: 0.52),
                    .init(color: .black.opacity(0.30), location: 0.62),
                    .init(color: .black.opacity(0.12), location: 0.72),
                    .init(color: .clear, location: 0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Midpoint blend of two colours for smoother gradient stops.
    private func mix(_ a: Color, _ b: Color) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .gray
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .gray
        return Color(
            red: Double(ca.redComponent + cb.redComponent) / 2,
            green: Double(ca.greenComponent + cb.greenComponent) / 2,
            blue: Double(ca.blueComponent + cb.blueComponent) / 2
        )
    }
}

private struct CoverHeatmap: View {
    let graph: ContributionGraph
    let theme: AppTheme

    var body: some View {
        // Columns justify space-between so the grid fills the full width with
        // equal gaps and equal left/right edges.
        HStack(spacing: 0) {
            let weeks = Array(graph.weeks.enumerated())
            ForEach(weeks, id: \.offset) { index, week in
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color(week[row]?.level ?? 0))
                            .frame(width: 6, height: 6)
                            .help(week[row].map {
                                "\($0.count) contribution\($0.count == 1 ? "" : "s") · \($0.date)"
                            } ?? "")
                    }
                }
                if index < weeks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Themed scale to pop against the cover; empty cells stay a faint white.
    private func color(_ level: Int) -> Color {
        guard level >= 1, level <= 4 else { return Color.white.opacity(0.12) }
        return theme.heat[level - 1]
    }
}

// MARK: - Rows

private struct DetailRow: View {
    let pr: PullRequest
    let showAuthor: Bool
    let ns: Namespace.ID
    let hovered: Bool
    let hoverNS: Namespace.ID
    let setHovered: (Bool) -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    // Dot aligned to the first line of the title
                    HStack(alignment: .top, spacing: 9) {
                        StatusDot(status: pr.ciStatus, size: 7, glow: false)
                            .padding(.top, 4)
                            .matchedGeometryEffect(id: "dot-\(pr.id)", in: ns)
                        Text(pr.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .matchedGeometryEffect(id: "title-\(pr.id)", in: ns, properties: .position, anchor: .topLeading)
                    }

                    // Status · repo · author — one line, uniform weight/size, • separated
                    metadataLine
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.leading, 16)
                        .padding(.top, 3)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 9) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovered ? .white : Color.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                    Text(RelativeTime.string(from: pr.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background {
                if hovered {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .matchedGeometryEffect(id: "hoverHighlight", in: hoverNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHovered($0) }
        .help("Open \(pr.repoShort) #\(pr.number) in browser")
    }

    private func open() {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func decisionColor(_ decision: ReviewDecision) -> Color {
        switch decision {
        case .approved:         return Color(hex: "5fe08a")
        case .changesRequested: return Color(hex: "ffb570")
        case .reviewRequired:   return Color(hex: "7cc0ff")
        }
    }

    /// Status · repo · author as one styled line, separated by bullets.
    private var metadataLine: Text {
        let sep = Text("  •  ").foregroundColor(.white.opacity(0.25))
        var line = Text(pr.isDraft ? "Draft" : "Open")
            .foregroundColor(pr.isDraft ? .white.opacity(0.55) : Color(hex: "5fe08a"))
        if let decision = pr.reviewDecision {
            line = line + sep + Text(decision.label).foregroundColor(decisionColor(decision))
        }
        line = line + sep + Text(pr.repoShort).foregroundColor(.white.opacity(0.5))
        line = line + sep + Text(pr.authorLogin ?? "you").foregroundColor(.white.opacity(0.5))
        return line
    }
}

private struct CompactRow: View {
    let pr: PullRequest
    let ns: Namespace.ID
    let hovered: Bool
    let hoverNS: Namespace.ID
    let setHovered: (Bool) -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                StatusDot(status: pr.ciStatus, size: 7, glow: false)
                    .matchedGeometryEffect(id: "dot-\(pr.id)", in: ns)
                Text(pr.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .matchedGeometryEffect(id: "title-\(pr.id)", in: ns, properties: .position, anchor: .topLeading)
                Spacer(minLength: 6)
                Text("#\(pr.number)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
                    .fixedSize()
                Text(RelativeTime.string(from: pr.updatedAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background {
                if hovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .matchedGeometryEffect(id: "hoverHighlight", in: hoverNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHovered($0) }
        .help("Open \(pr.repoShort) #\(pr.number) in browser")
    }

    private func open() {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Small pieces

private struct StatusDot: View {
    let status: CIStatus?
    let size: CGFloat
    let glow: Bool

    var body: some View {
        ZStack {
            if glow {
                Circle().fill(color.opacity(0.25)).frame(width: size + 6, height: size + 6)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .help(helpText)
    }

    private var color: Color {
        switch status {
        case .success:            return Color(hex: "3fb950")
        case .failure, .error:    return Color(hex: "f85149")
        case .pending, .expected: return Color(hex: "d29922")
        case .none:               return Color.white.opacity(0.45)
        }
    }

    private var helpText: String {
        switch status {
        case .success:            return "Checks passed"
        case .failure, .error:    return "Checks failed"
        case .pending, .expected: return "Checks running"
        case .none:               return "No checks"
        }
    }
}

// MARK: - States

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Fetching your pull requests…")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
    }
}

private struct EmptyStateView: View {
    enum Kind { case yours, people, deps }
    let tab: Kind

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var icon: String {
        switch tab {
        case .yours:  return "checkmark.seal"
        case .people: return "sparkles"
        case .deps:   return "shippingbox"
        }
    }
    private var message: String {
        switch tab {
        case .yours:  return "Nothing open"
        case .people: return "All caught up"
        case .deps:   return "No dependency PRs"
        }
    }
    private var detail: String {
        switch tab {
        case .yours:  return "You have no open pull requests."
        case .people: return "No pull requests are waiting on you."
        case .deps:   return "No bot pull requests need review."
        }
    }
}

/// First-run onboarding shown when `gh` is missing or the user isn't signed in.
private struct SetupStateView: View {
    let error: GitHubError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color(hex: "58c07d"))

            VStack(spacing: 5) {
                Text("Connect to GitHub")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Deal with PR reads your pull requests through the GitHub CLI. Two quick steps in Terminal:")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(1, done: error.ghInstalled, title: "Install the GitHub CLI", command: "brew install gh")
                stepRow(2, done: false, title: "Sign in to GitHub", command: "gh auth login")
            }
            .padding(14)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: retry) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.white.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(24)
    }

    private func stepRow(_ index: Int, done: Bool, title: String, command: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color(hex: "3fb950").opacity(0.2) : Color.white.opacity(0.1))
                    .frame(width: 20, height: 20)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: "5fe08a"))
                } else {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(done ? 0.5 : 0.9))
                .strikethrough(done)

            Spacer(minLength: 12)

            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

private struct ErrorStateView: View {
    let error: GitHubError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(Color(hex: "ffb570"))
            Text(error.errorDescription ?? "Something went wrong")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(error.hint)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(24)
    }
}

// MARK: - Color hex helper

// MARK: - Themes

/// A selectable colour theme: the hero gradient (top of the app) and the
/// contribution-graph dot palette.
struct AppTheme: Identifiable {
    let id: Int
    let name: String
    let cover: [Color]   // 3 stops, top-leading → bottom-trailing
    let heat: [Color]    // levels 1…4 (empty cells stay a faint white)
}

let appThemes: [AppTheme] = [
    AppTheme(
        id: 0, name: "Forest",
        cover: [Color(hex: "1c6f3a"), Color(hex: "0c3d20"), Color(hex: "123f52")],
        heat:  [Color(hex: "58c07d"), Color(hex: "7ad696"), Color(hex: "a5ebbb"), Color(hex: "d9fbe6")]
    ),
    AppTheme(
        id: 1, name: "Graphite",
        cover: [Color(hex: "3a3a40"), Color(hex: "1a1a1d"), Color(hex: "0b0b0d")],
        heat:  [Color(hex: "5f5f66"), Color(hex: "8a8a92"), Color(hex: "b4b4bc"), Color(hex: "e8e8ee")]
    ),
    AppTheme(
        id: 2, name: "Ocean",
        cover: [Color(hex: "1c5a9f"), Color(hex: "0c2340"), Color(hex: "103a52")],
        heat:  [Color(hex: "4c9bff"), Color(hex: "74b4ff"), Color(hex: "a5cdff"), Color(hex: "dbeeff")]
    ),
    AppTheme(
        id: 3, name: "Violet",
        cover: [Color(hex: "6a2ca0"), Color(hex: "2a1240"), Color(hex: "3a1c52")],
        heat:  [Color(hex: "b06be6"), Color(hex: "c98bf0"), Color(hex: "e0a5f6"), Color(hex: "f4d9fb")]
    ),
    AppTheme(
        id: 4, name: "Sunset",
        cover: [Color(hex: "b3541e"), Color(hex: "6e2a1c"), Color(hex: "3a1f52")],
        heat:  [Color(hex: "ff9a4d"), Color(hex: "ffb072"), Color(hex: "ffca9c"), Color(hex: "ffe6d0")]
    ),
    AppTheme(
        id: 5, name: "Rose",
        cover: [Color(hex: "a02c5a"), Color(hex: "4a1230"), Color(hex: "2a1240")],
        heat:  [Color(hex: "f06b9c"), Color(hex: "f68bb4"), Color(hex: "f6a5c8"), Color(hex: "fbd9e6")]
    ),
    AppTheme(
        id: 6, name: "Amber",
        cover: [Color(hex: "9f7a1c"), Color(hex: "4a3410"), Color(hex: "3a2e12")],
        heat:  [Color(hex: "f0c23a"), Color(hex: "f5d46b"), Color(hex: "f6e2a0"), Color(hex: "fbf3d0")]
    ),
    AppTheme(
        id: 7, name: "Slate",
        cover: [Color(hex: "3a4a5f"), Color(hex: "1a2530"), Color(hex: "10161e")],
        heat:  [Color(hex: "6b8299"), Color(hex: "8ba0b4"), Color(hex: "b4c4d0"), Color(hex: "e6eef4")]
    )
]

private extension Color {
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self = Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

// MARK: - Popover geometry

/// Shared corner radius for the popover, used by the SwiftUI content clip and by
/// the host `NSGlassEffectView`/panel (see PopoverPanel) so the two agree. The
/// glass and transparency now come from the panel we own, not from MenuBarExtra.
let popoverCornerRadius: CGFloat = 24
