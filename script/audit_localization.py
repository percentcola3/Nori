#!/usr/bin/env python3
"""Audit Swift user-facing literals without parsing comments or shell commands.

This deliberately checks presentation APIs and CJK prose, rather than treating
all Swift string values (paths, protocol keys, process names) as UI copy.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys

CJK = re.compile(r"[\u3400-\u9fff]")
UI_CALL = re.compile(
    r"(?:\b(?:Text|Button|Label|Toggle|TextField|SecureField|ProgressView|Section|"
    r"Picker|Menu|DevNotice|DevTag|DevCardTitle|DevLinkButton|NSMenuItem)\s*\(\s*"
    r"(?:verbatim\s*:\s*|title\s*:\s*)?|"
    r"\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle|alert|"
    r"confirmationDialog)\s*\(\s*|"
    r"\b(?:messageText|informativeText|prompt|title|subtitle|placeholder|summary|"
    r"confirmLabel|accessibilityLabel)\s*(?:=|:)\s*)$"
)

# Exact values only: these are identifiers or established technical labels,
# never exemptions for a file containing untranslated prose.
TECHNICAL_LITERALS = {
    "Nori", "ForgeSweep", "Terminal", "Finder", "TextEdit", "macOS", "iOS",
    "CPU", "RAM", "GPU", "SSD", "DNS", "DHCP", "HTTP", "HTTPS", "SOCKS",
    "PATH", "Nori PATH", "JAVA_HOME", "Shell", "SSH", "Git", "Docker",
    "Python", "Java / JVM", "Rust / Go", "JavaScript", "Node.js", "npm",
    "pnpm", "yarn", "pip", "pipx", "uv", "cargo", "rustup", "Homebrew",
    "nvm", "fnm", "pyenv", "rbenv", "SDKMAN", "asdf", "mise", "hosts", "Brew",
    "UTF-8", "JSON", "TOML", "Brewfile", "MB", "GB", "TB", "KB", "B",
    "PNG", "JPEG", "JPG", "HEIC", "WebP", "AVIF", "MP4", "MOV", "GIF",
    "HTTP / HTTPS", "SSH / Git", "API", "ID", "PID", "TCP", "UDP",
    "Wi-Fi", "IPv4", "IPv6", "iCloud", "App Store", "CLI", "SDK", "LTS",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY",
    "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "https://", "http://", "socks5://",
}
# Runtime identity matching must keep the actual process names in their native
# language; translating them would break protected-process detection.
IDENTITY_LITERALS = {"飞书", "微信", "钉钉"}
PRESENTATION_CALLS = {
    "Text", "Button", "Label", "Toggle", "TextField", "SecureField", "ProgressView",
    "Section", "Picker", "Menu", "DevNotice", "DevTag", "DevCardTitle", "DevLinkButton",
    "NSMenuItem", "help", "accessibilityLabel", "accessibilityHint", "navigationTitle",
    "alert", "confirmationDialog",
}


def presentation_argument(mask: str, position: int) -> bool:
    """Find an enclosing presentation argument, including conditional labels."""
    depth = 0
    for cursor in range(position - 1, -1, -1):
        char = mask[cursor]
        if char == "}":
            return False
        if char == "{" and depth == 0:
            return False
        if char == ")":
            depth += 1
        elif char == "(":
            if depth:
                depth -= 1
                continue
            prefix = mask[max(0, cursor - 80):cursor]
            called = re.search(r"\b([A-Za-z_][A-Za-z_0-9]*)\s*$", prefix)
            if called and called.group(1) in {"t", "tf", "localize", "localizedDefault"}:
                # A localization argument may contain conditional keys, string
                # concatenation or protocol-value comparisons. Its literals
                # are not the displayed result, even inside an outer Text.
                return False
            if called and called.group(1) in PRESENTATION_CALLS:
                # Symbol names, stable IDs and paths are API data even when
                # they are chosen conditionally inside a presentation call.
                argument = mask[cursor + 1:position]
                labels = re.findall(r"\b([A-Za-z_][A-Za-z_0-9]*)\s*:", argument)
                return not labels or labels[-1] not in {
                    "systemImage", "symbol", "id", "accessibilityIdentifier", "path",
                }
    return False


@dataclass(frozen=True)
class Literal:
    start: int
    end: int
    value: str


def swift_literals(source: str) -> tuple[list[Literal], str]:
    """Lex comments, raw/multiline strings and nested Swift interpolation.

    The returned mask preserves positions/newlines for call-site matching while
    blanking comments and strings; interpolation expressions are not UI prose.
    """
    mask = list(source)
    found: list[Literal] = []
    size = len(source)

    def blank(start: int, end: int) -> None:
        for index in range(start, end):
            if mask[index] != "\n":
                mask[index] = " "

    def comment(index: int) -> int:
        if source.startswith("//", index):
            end = source.find("\n", index)
            return size if end < 0 else end
        level, index = 1, index + 2
        while index < size and level:
            if source.startswith("/*", index):
                level += 1
                index += 2
            elif source.startswith("*/", index):
                level -= 1
                index += 2
            else:
                index += 1
        return index

    def string_at(index: int) -> tuple[int, str] | None:
        quote = index
        while quote < size and source[quote] == "#":
            quote += 1
        if quote >= size or source[quote] != '"':
            return None
        hashes = source[index:quote]
        delimiter = '"""' if source.startswith('"""', quote) else '"'
        end_token = delimiter + hashes
        cursor = quote + len(delimiter)
        start_content = cursor
        pieces: list[str] = []
        chunk = cursor
        escape = "\\" + hashes
        while cursor < size:
            if source.startswith(end_token, cursor):
                pieces.append(source[chunk:cursor])
                return cursor + len(end_token), "".join(pieces)
            if source.startswith(escape + "(", cursor):
                pieces.append(source[chunk:cursor])
                cursor += len(escape) + 1
                depth = 1
                while cursor < size and depth:
                    if source.startswith("//", cursor) or source.startswith("/*", cursor):
                        cursor = comment(cursor)
                    elif (nested := string_at(cursor)) is not None:
                        cursor = nested[0]
                    elif source[cursor] == "(":
                        depth += 1
                        cursor += 1
                    elif source[cursor] == ")":
                        depth -= 1
                        cursor += 1
                    else:
                        cursor += 1
                pieces.append("<value>")
                chunk = cursor
            elif source.startswith(escape, cursor):
                cursor += len(escape) + 1
            else:
                cursor += 1
        return size, source[start_content:]

    index = 0
    while index < size:
        if source.startswith("//", index) or source.startswith("/*", index):
            end = comment(index)
            blank(index, end)
            index = end
        elif (literal := string_at(index)) is not None:
            end, value = literal
            found.append(Literal(index, end, value))
            blank(index, end)
            index = end
        else:
            index += 1
    return found, "".join(mask)


def is_technical(value: str) -> bool:
    if value in TECHNICAL_LITERALS or value in IDENTITY_LITERALS:
        return True
    # Empty labels, pure runtime values, punctuation, numbers and units.
    remaining = re.sub(r"\\[ntr]", "", value.replace("<value>", "")).strip()
    if remaining.strip(" ·:/—–-()[]") in TECHNICAL_LITERALS:
        return True
    if not remaining or not re.search(r"[A-Za-z\u3400-\u9fff]", remaining):
        return True
    if re.fullmatch(r"(?:\d+(?:\.\d+)?\s*)?(?:[KMGT]?B|px|pt|ms|s|%)", remaining):
        return True
    if re.fullmatch(r"%[-+# 0-9.]*[diuoxXfFeEgGaA]%%?", remaining):
        return True
    # UI previews may show literal paths, URLs and raw identifier syntax.
    if re.fullmatch(r"(?:~?/|https?://)[^\s]+", remaining):
        return True
    return False


def audit_source(source: str) -> list[tuple[int, str, str]]:
    literals, mask = swift_literals(source)
    findings = []
    error_spans = []
    for match in re.finditer(r"\bvar\s+errorDescription\s*:\s*String\?\s*\{", mask):
        cursor, depth = match.end(), 1
        while cursor < len(mask) and depth:
            if mask[cursor] == "{":
                depth += 1
            elif mask[cursor] == "}":
                depth -= 1
            cursor += 1
        error_spans.append((match.end(), cursor))
    for literal in literals:
        if is_technical(literal.value):
            continue
        before = mask[max(0, literal.start - 350):literal.start].rstrip()
        # Dictionary keys are protocol data, including a lookup inside Text.
        # Restrict this to an actual named subscript; do not ignore array copy.
        if re.search(r"\b[A-Za-z_][A-Za-z_0-9.]*\s*\[\s*$", before):
            continue
        if re.search(r"\b(?:t|tf|localize|localizedDefault)\s*\(\s*$", before):
            continue
        # Embedded scripts and regular expressions are code, not prose. This
        # exclusion is based on the call/assignment, not on arbitrary keywords.
        line_before = source[source.rfind("\n", 0, literal.start) + 1:literal.start]
        code_value = re.search(r"\b(?:pattern|regex|script|command|arguments|"
                               r"executable|shellScript|sourceCode)\s*(?:=|:)\s*$", line_before)
        if code_value:
            continue
        if CJK.search(literal.value):
            kind = "CJK literal"
        elif (UI_CALL.search(before) or presentation_argument(mask, literal.start)
              or any(start <= literal.start < end for start, end in error_spans)):
            kind = "UI literal"
        else:
            continue
        line = source.count("\n", 0, literal.start) + 1
        findings.append((line, kind, literal.value))
    # Catch bilingual helpers even if their caller literals were migrated.
    for match in re.finditer(r"\bfunc\s+(?:choose|text|copy)\s*\(\s*_\s+(?:chinese|zh)\s*:\s*String\s*,\s*_\s+(?:english|en)\s*:\s*String", mask):
        findings.append((source.count("\n", 0, match.start()) + 1, "bilingual helper", match.group(0)))
    return sorted(set(findings))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    paths = args.paths or [Path(__file__).resolve().parents[1] / "SimpleMole"]
    files = sorted({file for path in paths for file in
                    (path.rglob("*.swift") if path.is_dir() else [path])})
    count = 0
    for path in files:
        if "L10n" in path.parts or path.name.endswith("Tests.swift"):
            continue
        for line, kind, value in audit_source(path.read_text(encoding="utf-8")):
            display = value.replace("\n", " ")
            print(f"{path}:{line}: {kind}: {display[:200]}")
            count += 1
    if count:
        print(f"Localization audit: {count} untranslated literals.", file=sys.stderr)
        return 1
    print("Localization audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
