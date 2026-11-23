#!/usr/bin/env python3
"""Flags user-facing text in the app's Swift code that can't be translated (#162).

    scripts/i18n/hardcoded-strings.py [FILE...]      (default: every .swift file in Shuffleboard/)

SwiftUI translates a string literal passed straight to Text, Button, Label, .help, .accessibilityLabel and the like,
so those are fine. What this catches is text that SwiftUI shows as it is:

  concatenation   A sentence built with + ("Showing " + count + " cards"): translators get the pieces, not the
                  sentence, and can't reorder them. Write one string with interpolation instead.
  plain String    Prose returned, assigned or picked by a switch as a plain String (`return "Can't connect"`,
                  `?? "Unknown"`, `case .offline: "You're offline."`), which reaches the screen untranslated. Wrap it
                  in String(localized:), or type the property as LocalizedStringKey or LocalizedStringResource.
  String(format:) A format string that isn't looked up. Use String(localized:) with interpolation.
  dateFormat      A fixed date format ignores the user's locale. Use Date.FormatStyle (`date.formatted(...)`).
  verbatim prose  Text(verbatim:) with a sentence, which is never translated.

It reads lines, not Swift's syntax, so it misses text passed to a String-typed parameter of the app's own functions
(`func row(_ title: String)` that calls Text(title)) and prose split oddly across lines; the catalog check in CI and
reviewing with the pseudo-language (CONTRIBUTING.md) catch more. Prose means a literal that starts with a capital
letter and has another word or ends a sentence; identifiers, keys and URLs don't look like that.

A line that is meant to stay as it is (an app or product name, a developer message) can end with
`// i18n-ignore: <reason>`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Shuffleboard"

STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
# Starts with a capital and has a second word, or ends a sentence: "Can't reach the server", "Done.".
PROSE = re.compile(r"^[A-Z][a-z'’]*(?:[ ,][^ ]|[a-z]*[.!?…]$)")
# A single capitalised word, which reads as UI text when it's a fallback or a switch's result ("Unknown").
WORD = re.compile(r"^[A-Z][a-z]{2,}$")
# Lines that are already translated, or that aren't text the user sees.
TRANSLATED = re.compile(
    r"String\(localized:|LocalizedStringResource|LocalizedStringKey|IntentDialog|IntentDescription"
    r"|TypeDisplayRepresentation|DisplayRepresentation|Text\(|Logger|[lL]ogger\.|\.(notice|debug|info|error|fault)\("
    r"|fatalError|precondition|assert|accessibilityIdentifier|debugDescription"
)
# A declaration whose body produces translated text: its literals are LocalizedStringKey or -Resource.
TRANSLATED_BODY = re.compile(r"(var|func)\b.*\b(LocalizedStringResource|LocalizedStringKey|IntentDialog|Text)\b.*\{\s*$")
IGNORE = "// i18n-ignore"


def strip_comment(line: str) -> str:
    """The line without a trailing // comment (a // inside a string, as in a URL, stays)."""
    in_string = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and in_string:
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", index):
            return line[:index].rstrip()
        index += 1
    return line


def literals(line: str) -> list[tuple[int, int, str]]:
    """The string literals on the line (start, end, contents)."""
    return [(match.start(), match.end(), match.group(0)[1:-1]) for match in STRING.finditer(line)]


def text_of(literal: str) -> str:
    """The literal's text with interpolations as a placeholder word."""
    return re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "x", literal)


def is_prose(literal: str) -> bool:
    return bool(PROSE.match(text_of(literal)))


def check_file(path: Path) -> list[str]:
    problems = []
    lines = path.read_text(encoding="utf-8").splitlines()
    depth = 0
    skip_until: int | None = None
    in_multiline = False
    previous = ""
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        code = strip_comment(line)
        # On the line, or on a comment line of its own just above it.
        ignored = IGNORE in raw or (previous.startswith("//") and IGNORE in previous)
        opened = code.count("{") - code.count("}")
        if skip_until is None and (TRANSLATED_BODY.search(code) or line.startswith("#Preview")):
            skip_until = depth
        depth += opened
        if skip_until is not None:
            if depth <= skip_until:
                skip_until = None
            previous = line
            continue
        if line.count('"""') % 2 == 1:
            in_multiline = not in_multiline
            if in_multiline:
                # A multi-line literal: judge it by its opening line.
                if re.search(r'(return|=|\?\?)\s*"""$', code) and not TRANSLATED.search(code):
                    following = lines[number].strip() if number < len(lines) else ""
                    if is_prose(following) and not ignored:
                        problems.append(f"{path}:{number}: plain String: wrap the text in String(localized:)")
            previous = line
            continue
        if in_multiline or line.startswith("//") or line.startswith("*") or ignored:
            previous = line
            continue
        found = literals(code)
        for start, end, literal in found:
            before = code[:start].rstrip()
            after = code[end:].lstrip()
            text = text_of(literal)
            # Words, or a word with a space on the side it's joined on ("Starts " + date).
            prose_piece = bool(
                re.search(r"[A-Za-z]{2,}\s+[A-Za-z]{2,}|[A-Za-z]{2,}[.!?…]$", text)
                or (after.startswith("+") and re.search(r"[A-Za-z]{2,} $", text))
                or (before.endswith("+") and re.match(r"^ [A-Za-z]{2,}", text))
            )
            if prose_piece and (before.endswith("+") or after.startswith("+")):
                problems.append(f"{path}:{number}: concatenation: write the sentence as one string")
                continue
            if before.endswith("String(format:"):
                problems.append(f"{path}:{number}: String(format:): use String(localized:) with interpolation")
                continue
            if re.search(r"\.dateFormat\s*=$", before):
                problems.append(f"{path}:{number}: dateFormat: use Date.FormatStyle, which follows the locale")
                continue
            if before.endswith("Text(verbatim:") and is_prose(literal):
                problems.append(f"{path}:{number}: verbatim prose: Text(verbatim:) is never translated")
                continue
            if TRANSLATED.search(code):
                continue
            in_value_position = (
                re.search(r"(\breturn|[^=!<>]=|\?\?)$", before)
                or re.match(r"^(case\b.*|default):$", before)
                # A switch expression's result on a line of its own.
                or (before == "" and after == "" and re.match(r"^(case\b.*|default):$", previous))
            )
            if in_value_position and (is_prose(literal) or (WORD.match(literal) and "??" in before[-3:])):
                problems.append(f"{path}:{number}: plain String: wrap the text in String(localized:)")
        previous = line
    return problems


def main(argv: list[str]) -> int:
    paths = [Path(arg) for arg in argv] or sorted(SOURCES.rglob("*.swift"))
    problems = [problem for path in paths for problem in check_file(path)]
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        print(
            f"{len(problems)} user-facing strings can't be translated; see scripts/i18n/hardcoded-strings.py and "
            "CONTRIBUTING.md. End a line with `// i18n-ignore: <reason>` if it's meant to stay as it is.",
            file=sys.stderr,
        )
        return 1
    print(f"No hard-coded user-facing strings in {len(paths)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
