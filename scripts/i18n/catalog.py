#!/usr/bin/env python3
"""Checks the app's String Catalogs (#162).

    scripts/i18n/catalog.py lint
        Checks every catalog in Shuffleboard/ on its own (any OS): it parses, its source language is English, and
        every translation and plural form formats the same arguments as its key.

    scripts/i18n/catalog.py check DERIVED_DATA [--write]
        Compares the catalogs with the strings the compiler found in the app's code, from the `.stringsdata` files a
        build with SWIFT_EMIT_LOC_STRINGS=YES leaves in DERIVED_DATA (macOS, after `xcodebuild build`). Fails if the
        code uses a key a catalog doesn't have (it would never be translated), or a catalog has a key the code no
        longer uses. With --write, adds the missing keys and removes the unused ones instead, as building in Xcode
        does; then give any new count a plural form (see CONTRIBUTING.md).

Xcode keeps the catalogs in step with the code by itself when you build in the IDE; `xcodebuild` doesn't, which is
why CI checks. Only the compiler knows each interpolated value's type, which decides its specifier in the key
(`\\(count)` is `%lld` for an Int, `%@` for a String), so `check` reads its output rather than the Swift sources.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_DIR = ROOT / "Shuffleboard"
# The target whose code looks strings up in these catalogs.
TARGET_BUILD_DIR = "Shuffleboard.build"
SOURCE_LANGUAGE = "en"

# printf-style specifiers, as String(localized:) and SwiftUI write them, plus App Intents' ${parameter}.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])")
PARAMETER = re.compile(r"\$\{(\w+)\}")
SUBSTITUTION = re.compile(r"%(?:(\d+)\$)?#@(\w+)@")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def dump(catalog: dict) -> str:
    """The catalog as Xcode writes it, so a later edit in Xcode doesn't reformat the file."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True) + "\n"


def catalogs() -> dict[str, Path]:
    """The app's catalogs by table name (Localizable.xcstrings is the "Localizable" table)."""
    return {path.stem: path for path in sorted(CATALOG_DIR.glob("*.xcstrings"))}


# MARK: - Lint


def specifiers(text: str) -> list[str]:
    """The kinds of argument `text` formats, in argument order. `%%` is a literal percent sign."""
    text = text.replace("%%", "")
    found = []
    for match in SPECIFIER.finditer(text):
        found.append((int(match.group(1)) if match.group(1) else None, (match.group(2) or "") + match.group(3)))
    if any(position is not None for position, _ in found):
        found.sort(key=lambda item: item[0] or 0)
    return [kind for _, kind in found] + sorted(PARAMETER.findall(text))


def units(localization: dict, path: str = "") -> list[tuple[str, dict]]:
    """Every string of one language's localization, through its plural or device variations."""
    found = []
    if "stringUnit" in localization:
        found.append((path, localization["stringUnit"]))
    for kind, cases in localization.get("variations", {}).items():
        for case, nested in cases.items():
            found += units(nested, f"{path}/{kind}.{case}")
    for name, substitution in localization.get("substitutions", {}).items():
        found += units(substitution, f"{path}/{name}")
    return found


def expand(value: str, localization: dict) -> str:
    """`value` with each %#@name@ substitution replaced by its argument's specifier, to compare with the key."""

    def specifier(match: re.Match) -> str:
        substitution = localization.get("substitutions", {}).get(match.group(2), {})
        kind = substitution.get("formatSpecifier", "@")
        return f"%{match.group(1)}${kind}" if match.group(1) else f"%{kind}"

    return SUBSTITUTION.sub(specifier, value)


def lint_catalog(name: str, catalog: dict) -> list[str]:
    errors = []
    if catalog.get("sourceLanguage") != SOURCE_LANGUAGE:
        errors.append(f"{name}: the source language must be {SOURCE_LANGUAGE!r}")
    for key, entry in catalog.get("strings", {}).items():
        expected = specifiers(key)
        for language, localization in entry.get("localizations", {}).items():
            where = f"{name} {language}: {key!r}"
            for path, unit in units(localization):
                if unit.get("state") not in ("translated", "needs_review", "new", "stale"):
                    errors.append(f"{where}{path}: unknown state {unit.get('state')!r}")
            if "stringUnit" in localization:
                value = localization["stringUnit"].get("value", "")
                if specifiers(expand(value, localization)) != expected:
                    errors.append(f"{where}: {value!r} doesn't format the same arguments as the key")
            plural = localization.get("variations", {}).get("plural", {})
            if plural and "other" not in plural:
                errors.append(f"{where}: plural forms but no \"other\" one")
            for case, nested in plural.items():
                value = nested.get("stringUnit", {}).get("value", "")
                # A form may spell its number out ("Every minute"), so it may format nothing.
                if specifiers(value) not in ([], expected):
                    errors.append(f"{where} ({case}): {value!r} doesn't format the same arguments as the key")
            for substitution_name, substitution in localization.get("substitutions", {}).items():
                cases = substitution.get("variations", {}).get("plural", {})
                if cases and "other" not in cases:
                    errors.append(f"{where}: substitution {substitution_name} has no \"other\" form")
    return errors


def lint() -> int:
    errors = []
    found = catalogs()
    if "Localizable" not in found:
        errors.append(f"No Localizable.xcstrings in {CATALOG_DIR.relative_to(ROOT)}")
    for name, path in found.items():
        try:
            catalog = load(path)
        except json.JSONDecodeError as error:
            errors.append(f"{path.name}: not valid JSON: {error}")
            continue
        errors += lint_catalog(path.name, catalog)
        if path.read_text(encoding="utf-8") != dump(catalog):
            errors.append(f"{path.name}: not formatted as Xcode writes it; run scripts/i18n/catalog.py format")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"{len(found)} catalogs OK: " + ", ".join(
            f"{path.name} ({len(load(path).get('strings', {}))} keys)" for path in found.values()))
    return 1 if errors else 0


def format_catalogs() -> int:
    for path in catalogs().values():
        path.write_text(dump(load(path)), encoding="utf-8")
    return 0


# MARK: - Check against the code


def extracted(derived_data: Path) -> dict[str, dict[str, list[str]]]:
    """The keys the compiler extracted from the app's code: {table: {key: [comments]}}."""
    def is_app(path: Path) -> bool:
        # .../Intermediates.noindex/<project>.build/<configuration>/<target>.build/...: the project is called
        # Shuffleboard too, so look at the target's folder.
        parts = path.parts
        if "Intermediates.noindex" in parts:
            index = parts.index("Intermediates.noindex")
            return len(parts) > index + 3 and parts[index + 3] == TARGET_BUILD_DIR
        return TARGET_BUILD_DIR in parts

    files = [path for path in derived_data.rglob("*.stringsdata") if is_app(path)]
    if not files:
        sys.exit(f"No .stringsdata for the app in {derived_data}: build it first, with SWIFT_EMIT_LOC_STRINGS=YES")
    tables: dict[str, dict[str, list[str]]] = {}
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                comments = tables.setdefault(table, {}).setdefault(entry["key"], [])
                comment = entry.get("comment")
                if comment and comment not in comments:
                    comments.append(comment)
    return tables


def check(derived_data: Path, write: bool) -> int:
    found = catalogs()
    code = extracted(derived_data)
    problems = 0
    for table in sorted(set(code) | set(found)):
        path = found.get(table, CATALOG_DIR / f"{table}.xcstrings")
        catalog = load(path) if path.exists() else {"sourceLanguage": SOURCE_LANGUAGE, "strings": {}, "version": "1.0"}
        strings = catalog.setdefault("strings", {})
        used = code.get(table, {})
        missing = sorted(key for key in used if key not in strings)
        unused = sorted(key for key, entry in strings.items()
                        if key not in used and entry.get("extractionState") != "manual")
        for key in missing:
            print(f"{'added' if write else 'error'}: {path.name}: the code uses {key!r}, which isn't in the catalog")
            entry = {}
            if used[key]:
                entry["comment"] = "\n".join(used[key])
            strings[key] = entry
        for key in unused:
            print(f"{'removed' if write else 'error'}: {path.name}: no code uses {key!r} any more")
            del strings[key]
        if write:
            # Translators see the code's comments; Xcode copies them in on every build.
            for key, comments in used.items():
                if comments:
                    strings[key]["comment"] = "\n".join(comments)
                else:
                    strings[key].pop("comment", None)
            if dump(catalog) != (path.read_text(encoding="utf-8") if path.exists() else ""):
                path.write_text(dump(catalog), encoding="utf-8")
        problems += len(missing) + len(unused)
    if problems and not write:
        print(
            f"{problems} differences between the String Catalogs and the code. Build in Xcode, which updates the "
            "catalogs, or run scripts/i18n/catalog.py check <DerivedData> --write after an xcodebuild build; give "
            "any new count a plural form (CONTRIBUTING.md).",
            file=sys.stderr,
        )
        return 1
    if not problems:
        print(f"The String Catalogs have every key the code uses ({sum(len(keys) for keys in code.values())}).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("lint", help="check the catalogs on their own")
    commands.add_parser("format", help="write the catalogs as Xcode does")
    check_parser = commands.add_parser("check", help="compare the catalogs with a build's extracted strings")
    check_parser.add_argument("derived_data", type=Path)
    check_parser.add_argument("--write", action="store_true", help="update the catalogs instead of failing")
    args = parser.parse_args()
    if args.command == "lint":
        return lint()
    if args.command == "format":
        return format_catalogs()
    return check(args.derived_data, args.write)


if __name__ == "__main__":
    sys.exit(main())
