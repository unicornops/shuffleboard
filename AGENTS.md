# Agent instructions for Shuffleboard

This document gives coding agents (e.g. Cursor, GitHub Copilot, Claude) shared context for working in this repository. Follow it when editing code, writing commits, or reviewing changes.

## Project overview

- **What it is:** Shuffleboard, an unofficial native macOS client for [Nextcloud Deck](https://github.com/nextcloud/deck) with a Trello-like board UI. It is an independent project, not affiliated with or endorsed by Nextcloud.
- **Naming:** Follow the [Nextcloud trademark guidelines](https://nextcloud.com/trademarks/): never put "Nextcloud" in the app's name, never use the Nextcloud logo or its brand blue (`#0082c9`) in the app's branding, and always say the app is unofficial. Describing compatibility ("a client for Nextcloud Deck") is fine. The bundle ID is `ie.unicornops.shuffleboard`; the Keychain service is the same string.
- **Stack:** Swift, SwiftUI, macOS 14.0+. Built with Xcode; project is `Shuffleboard.xcodeproj`.
- **Auth:** Nextcloud Login Flow v2 (browser sign-in); app password stored in system Keychain (see `KeychainStorage.swift`, `NextcloudAuth.swift`).
- **Layout:** `Shuffleboard/` — Models (Board, Stack, Card, Label), Services (DeckAPI, NextcloudAuth, KeychainStorage), Views (Login, board list, board detail, cards, stacks), Helpers (e.g. Color+Hex).

## Developer tooling

The project uses the following tools to enforce code quality. They run via pre-commit, and on every PR: `swiftformat --lint` and `swiftlint lint --strict` in the `SwiftLint and SwiftFormat` job (pinned versions in `.github/workflows/pr-validation.yml`, so any warning fails the build), and PMD copy-paste detection in the `PMD Static Analysis` job. Run `swiftformat .` and `swiftlint lint --fix` before committing; the two configs are set up so they agree.

| Tool | Purpose | Config |
|------|---------|--------|
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | Code formatting | `.swiftformat` |
| [SwiftLint](https://github.com/realm/SwiftLint) | Style & lint rules | `.swiftlint.yml` |
| [PMD](https://pmd.github.io) | Static analysis + copy-paste detection | `pmd-ruleset.xml` |
| [pre-commit](https://pre-commit.com) | Runs all checks before each commit | `.pre-commit-config.yaml` |

Install all tools: `brew install pre-commit swiftformat swiftlint pmd`

### PMD rules

All four built-in PMD Swift rules are enabled in `pmd-ruleset.xml`:

- **`ProhibitedInterfaceBuilder`** (priority 2) — flags accidental `@IBOutlet`/`@IBAction`/`@IBInspectable` usage. This is a pure SwiftUI app; Interface Builder attributes must not appear.
- **`UnavailableFunction`** (priority 2) — `@available(*, unavailable)` stubs (e.g. `required init?(coder:)`) must call `fatalError()`, not return silently.
- **`ForceCast`** (priority 1, error) — `as!` crashes at runtime if the cast fails; use `as?` or typed `Codable` decoding instead.
- **`ForceTry`** (priority 1, error) — `try!` suppresses structured error handling; all network and Keychain paths use `async/await` with explicit error propagation.

PMD CPD (copy-paste detection) is also run with a 50-token minimum to flag duplicated blocks that should be extracted.

To suppress a violation in source (use sparingly, with a reason):

```swift
let value = foo as! Bar // NOPMD - safe: type is guaranteed by the API contract
```

## Conventional commits

Use [Conventional Commits](https://www.conventionalcommits.org/) for every commit. The project uses release-please with these types:

- **feat:** New feature (maps to “Features” in CHANGELOG).
- **fix:** Bug fix (maps to “Bug Fixes”).
- **docs:** Documentation only.
- **chore:** Maintenance, tooling, deps (maps to “Miscellaneous”).

Format: `<type>(<scope>): <short description>`. Scope is optional (e.g. `feat(api): add label filters`). Keep the subject line concise; add a body when the change needs explanation.

Examples:

- `feat(boards): add archive filter`
- `fix(auth): handle expired app password`
- `docs: update API links in README`
- `chore(deps): bump Swift tools version`

Do not use other types (e.g. `refactor`, `style`) unless you add matching `changelog-sections` in `release-please-config.json`.

## Upstream API reference

All Deck server interaction must follow the official API. Reference it when adding or changing endpoints or request/response shapes.

- **Deck REST API (v1.0):** https://deck.readthedocs.io/en/latest/API/
- **Nextcloud Login Flow / app password:** https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html

Implementation details:

- Base path: `/index.php/apps/deck/api/v1.0` (see `DeckAPI.swift`); attachments use `/index.php/apps/deck/api/v1.1`, because v1.0 only handles `deck_file` attachments.
- Use documented endpoints only — not the internal routes the Deck web UI calls (`/index.php/apps/deck/cards/...`), which can change in any release.
- Use `OCS-APIRequest: true` and `Content-Type` / `Accept: application/json` where specified by the API.
- Authentication: Basic auth with username and app password (no account password in requests).
- When adding or changing endpoints, DTOs, or error handling, check the upstream docs for paths, methods, query/body parameters, and response formats so the client stays in sync with the server.

## Apple / Swift style and APIs

Follow Apple’s official guidance so the codebase stays consistent and idiomatic:

- **Swift API Design Guidelines:** https://www.swift.org/documentation/api-design-guidelines/
  - Clarity at the point of use; fluent naming; clear argument labels; documentation comments for public API.
- **SwiftUI and macOS:** Use current SwiftUI patterns, toolbars, sidebar, materials, and system controls. Prefer declarative UI and native macOS look and behavior.
- **Conventions in this repo:** Match existing patterns (e.g. `// MARK: -` sections, `async/await` for network, `final class` for service types, explicit error handling with `DeckAPIError`).
- **Translatable text (#162):** All user-facing text goes through `Shuffleboard/Localizable.xcstrings`: literals straight to SwiftUI, `String(localized:)` elsewhere, `LocalizedStringKey` for parameters that take text to show, whole sentences with interpolation (never `+`), plural forms for counts, and `Date.FormatStyle`/`.formatted()` for dates and numbers. Add new keys to the catalog in the same change (CI checks). See [CONTRIBUTING.md](CONTRIBUTING.md#writing-code-that-can-be-translated).

When in doubt, prefer Apple’s Human Interface Guidelines and Swift API Design Guidelines over ad-hoc style.

## Security

Code with security in mind:

- **Credentials:** Store only in the system Keychain via `KeychainStorage`; never log or persist app passwords in plain text. Use app password (from Login Flow or user input), not the main Nextcloud account password, for API calls.
- **Network:** Use HTTPS for all Nextcloud URLs. Validate server URLs and certificates; avoid disabling TLS or certificate checks. Keep `URLSession` usage consistent with existing `DeckAPI` (no custom insecure configurations).
- **Input:** Validate and sanitize user input (server URL, board/stack/card titles, descriptions) before sending to the API or displaying. Guard against injection and overly large or malformed payloads where relevant.
- **Secrets:** No API keys, passwords, or tokens in source code, config files, or logs. Use Keychain and environment or build-time configuration for any future secrets.
- **Dependencies:** Prefer system frameworks and a minimal dependency set; if adding packages, choose well-maintained ones and review for known vulnerabilities.

When adding auth flows, storage, or network code, explicitly consider how credentials and PII are handled and that the app remains safe on a shared or managed Mac.

---

*This file is the single source of agent instructions. `CLAUDE.md` and `.github/copilot-instructions.md` may point here so all agents use the same rules.*
