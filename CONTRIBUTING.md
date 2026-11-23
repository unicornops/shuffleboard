# Contributing to Shuffleboard

Thanks for helping. Code changes follow [AGENTS.md](AGENTS.md) (style, conventional commits, the Deck API) and the developer tooling in the [README](README.md#developer-tooling). This page is about translations.

## Translating Shuffleboard

Shuffleboard is ready for translation (#162), but it only ships in English so far. Every piece of text the app shows is in one [String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog), `Shuffleboard/Localizable.xcstrings`, with English as the source language. Dates, times, numbers and file sizes already follow the language and region set on the Mac, and counts take the plural form of the language ("1 card", "3 cards").

What isn't translated: anything that comes from your Nextcloud server, such as board, list, card and label names, people's names, and the messages in a card's Activity, which the server writes in the language set in your Nextcloud.

### Adding or improving a language

Translations come in as pull requests to the catalog.

1. Fork the repository and open `Shuffleboard.xcodeproj` in Xcode 15 or later.
2. Select `Localizable.xcstrings` in the project navigator. To add a language, click **+** at the bottom of the language list and pick it; Xcode adds it to the project too (Project → Info → Localizations).
3. Translate each string in the right-hand column. The **Comment** column says where a string appears when that isn't obvious.
   - Keep each placeholder: `%@` is text (a name, a date), `%lld` is a whole number. If your language needs them in another order, number them: `%2$@ … %1$@`.
   - For a string with plural forms (it says **Vary by Plural** in English), fill in each form your language has. Xcode shows the right ones ("one", "few", "many", "other"…).
   - Keep "Shuffleboard", "Deck" and "Nextcloud" as they are: they're names.
   - Mark a string you're not sure about **Needs Review** (right-click it).
4. Run the app in your language to check that nothing is cut off: Product → Scheme → Edit Scheme… → Run → Options → **App Language**.
5. Open a pull request titled `feat(i18n): add <language> translation` (or `fix(i18n): …` for corrections). Say whether you're a native speaker; another speaker of the language reviewing it is welcome.

You can also edit the catalog without Xcode: it's JSON. Copy an English entry's shape, with your language's code (`de`, `fr`, `pt-BR`…) next to `en`, and run `python3 scripts/i18n/catalog.py lint`, which checks that each translation keeps the placeholders and has an "other" plural form. If none of this suits you, open an issue with your translations and someone will add them.

A language ships once it's complete enough that the app doesn't switch between it and English on every screen; strings added later stay in English until someone translates them. A translation isn't merged if its placeholders don't match English, since that garbles the text or crashes the app.

### Writing code that can be translated

When you add text to the app:

- Pass string literals straight to SwiftUI: `Text("Archived cards")`, `Button("Delete")`, `.help("…")`, `.accessibilityLabel("…")`. SwiftUI looks them up in the catalog.
- Anywhere else, such as an error's `errorDescription`, a model's `title` or a notification, use `String(localized: "…")`. A parameter that takes text to show should be `LocalizedStringKey` (or `LocalizedStringResource`), not `String`.
- Write whole sentences with interpolation, never with `+`: `"Showing \(shown) of \(total) cards."`. Word order differs between languages, and a translator can only reorder what's in one string. For quotes around a name, put them in the string (`"“\(title)” will be deleted."`), since quote marks differ too.
- Give a count a plural form in the catalog: select the string, then **Vary by Plural** (or copy `%lld comments` in the JSON). For a count in the middle of a sentence, see `Showing %lld of %lld cards…`.
- Format dates and numbers for the locale, with `date.formatted(…)`, `Text(date, format: …)`, `Text(count, format: .number)` or `.formatted(.list(type: .and))`, never a fixed `dateFormat` or `String(format:)`.
- Use `.accessibilityIdentifier("…")`, which is never translated, for anything a UI test finds by name, and `Text(verbatim:)` only for text that isn't a word, like "•".
- Add a `comment:` when a string is ambiguous on its own ("Done" the button, or "Done" the state).

Building in Xcode adds new strings to the catalog. Commit the catalog with your change: CI fails if a key the code uses is missing from it, or if it has one no code uses any more. From the command line, `xcodebuild build` doesn't update the catalog, so run `python3 scripts/i18n/catalog.py check <DerivedData> --write` afterwards (the failed CI run also uploads the updated catalog as the `string-catalogs` artifact).

### What the checks catch

- **`scripts/i18n/hardcoded-strings.py`** (every pull request, and pre-commit) reads the Swift code for text SwiftUI would show untranslated: sentences built with `+`, prose returned or assigned as a plain `String` (`return "Can't connect"`, `?? "Unknown"`, a `switch` that picks a sentence), `String(format:)`, fixed date formats, and prose in `Text(verbatim:)`. It works line by line, so it misses a `String` passed through one of the app's own functions to `Text`; reviews and the pseudo-language catch those. If a line is meant to stay as it is (an app's name, an HTTP header), mark it with `// i18n-ignore: <reason>` on the line or the line above.
- **`scripts/i18n/catalog.py lint`** (every pull request) checks the catalog itself: English source language, placeholders that match in every language and plural form, and an "other" plural form.
- **`scripts/i18n/catalog.py check`** (every pull request, after the build) compares the catalog with the strings the compiler found in the code.
- **`LocalizationTests`** (unit tests) check that the catalog is built into the app and that counts take their plural forms.

### The pseudo-language

The double-length pseudo-language shows every translated string twice ("Save Save"), about as long as German or Finnish can be. Text that isn't doubled isn't going through the catalog; text that is cut off needs a layout that can grow.

- In Xcode: Edit Scheme… → Run → Options → App Language → **Double-Length Pseudolanguage**. There are also Right-to-Left and Accented pseudolanguages there.
- From the command line: `open Shuffleboard.app --args -NSDoubleLocalizedStrings YES`.
- In CI: the daily end-to-end run runs the UI tests in the pseudo-language and keeps their screenshots as the `screenshots-pseudo-language` artifact. Run it by hand with Actions → End-to-end tests → Run workflow → profile **pseudo-language**. Locally, `TEST_RUNNER_E2E_PSEUDO_LANGUAGE=double scripts/e2e/test.sh ui` (and `… screenshots`).

The UI tests find text through `ui("…")` in `UITestSupport.swift`, which doubles it in the pseudo-language, so they pass in both.
