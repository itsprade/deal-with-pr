# Deal with PR

A tiny, delightful macOS **menu-bar app** that shows the GitHub pull requests that need
your attention — at a glance, with **no login**.

Click the menu-bar icon and a popover shows three tabs:

- **Your PRs** — the PRs you've authored (drafts first), each with its review decision
  (Approved / Changes / In review) and a CI status dot.
- **People** — PRs where your review is requested by a human.
- **Deps** — dependency PRs from bots (renovate / dependabot), kept separate so they never
  bury a real request.

Up top, a **liquid-glass hero** shows your current contribution streak, your GitHub
contribution graph for the last year, and merged-PR counts (this month → last year).

The menu-bar icon shows a **badge** with the number of reviews waiting on you, and you get
a native **notification** when a new review request lands. Everything refreshes
automatically every few minutes (and each time you open the popover).

It's **read-only**: the only action is clicking a PR to open it in your browser.

## Why there's no login

Pull requests live on GitHub's servers, not in your local `.git`. This app does no auth of
its own — it shells out to the **GitHub CLI (`gh`)**, which you're already signed into. No
OAuth, no tokens stored by this app, nothing to configure.

## Requirements

- **macOS 14 (Sonoma)** or newer
- **[GitHub CLI](https://cli.github.com)** — `brew install gh`
- **Signed in once** — `gh auth login`

If `gh` is missing or you're not signed in, the app shows a short setup screen instead of
failing silently.

## Install

Download the latest `Deal with PR.app` from
[Releases](https://github.com/itsprade/deal-with-pr/releases) and drag it to Applications.
Because the app is distributed outside the App Store, the first launch may need a
**right-click → Open** to approve it in Gatekeeper.

To start it at login: **System Settings → General → Login Items → +**.

## Build from source

```sh
git clone https://github.com/itsprade/deal-with-pr.git
cd deal-with-pr
sh build-app.sh
open "Deal with PR.app"
```

`build-app.sh` runs `swift build -c release`, assembles the `.app` bundle (with
`LSUIElement` so there's no Dock icon), and ad-hoc signs it. For quick iteration you can
also `swift run`, though menu-bar behavior is best tested from the built `.app`.

## How it works

A single `gh api graphql` call returns everything — both PR lists, review decisions, CI
status, the contribution calendar, and merged-PR counts:

- `viewer.pullRequests(states: OPEN)` → your authored PRs
- `search(query: "is:open is:pr review-requested:@me")` → review requests
- `viewer.contributionsCollection` → streak + contribution graph

Built with SwiftUI's `MenuBarExtra`. No third-party dependencies. Source is under
[`Sources/DealWithPR/`](Sources/DealWithPR/).

## Security & privacy

- **No credentials touched.** The app never sees, stores, or transmits your GitHub token —
  `gh` holds it in the macOS keychain.
- **No network code of its own.** All network I/O is done by `gh` over HTTPS. The app opens
  zero connections itself.
- **No data at rest.** PR data lives in memory only; the sole thing persisted is your theme
  choice. No caching, no logs of sensitive data, **no analytics or telemetry**.
- **No dependencies.** Pure SwiftUI + the system `gh` — nothing to compromise via a supply
  chain.
- **Read-only.** It shows and opens PRs. It never merges, comments, or modifies anything.

## Contributing

Issues and PRs are welcome. Please keep the app small and focused — it's meant to stay a
tiny, read-only utility. Match the existing SwiftUI patterns in `Sources/DealWithPR/`.

## License

[MIT](LICENSE) © 2026 Pradeep
