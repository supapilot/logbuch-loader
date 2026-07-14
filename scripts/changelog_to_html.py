#!/usr/bin/env python3
"""Extrahiert den Changelog-Abschnitt einer Version.

Aufruf:  changelog_to_html.py <version> [CHANGELOG.md] [--raw]

Standard: HTML-*Fragment* (kein DOCTYPE/<body>), das Sparkles `generate_appcast`
als CDATA-<description> einbettet und im Update-Dialog anzeigt.
Mit `--raw`: der unveränderte Markdown-Abschnitt – als einzige Quelle für die
Release-Notes (GitHub-Release, manueller Hinweis), damit die Abschnitts-Extraktion
nicht in mehreren `sed`-Varianten dupliziert wird.
"""
import html
import re
import sys


def extract_section(text: str, version: str) -> str:
    """Liefert die Zeilen zwischen `## [<version>]` und der nächsten `## [`."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"## [{version}]"):
            start = i + 1
            break
    if start is None:
        sys.exit(f"Version {version} nicht im Changelog gefunden.")
    body = []
    for line in lines[start:]:
        if line.startswith("## ["):
            break
        body.append(line)
    return "\n".join(body).strip()


def inline_md(text: str) -> str:
    """Wandelt Inline-Markdown in HTML (nach dem HTML-Escaping des Rohtexts)."""
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def to_html(section: str) -> str:
    """Rendert Header (`### `), Listen (`- `) und Absätze. Über mehrere Zeilen
    umgebrochene Listeneinträge/Absätze werden zu einem Element zusammengefügt
    (eine Leerzeile trennt Elemente, eine eingerückte Folgezeile setzt fort)."""
    out, items, prev_blank = [], [], True

    def flush_list():
        if items:
            out.append("<ul>")
            out.extend(f"<li>{inline_md(t)}</li>" for t in items)
            out.append("</ul>")
            items.clear()

    for raw in section.splitlines():
        line = raw.strip()
        if line.startswith("### "):
            flush_list()
            out.append(f"<h4>{inline_md(line[4:])}</h4>")
        elif line.startswith("- "):
            items.append(line[2:])
        elif not line:
            pass
        elif not prev_blank and items:
            items[-1] += " " + line  # Fortsetzung des letzten Listeneintrags
        else:
            flush_list()
            out.append(f"<p>{inline_md(line)}</p>")
        prev_blank = not line
    flush_list()
    return "\n".join(out)


def main() -> None:
    raw = "--raw" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit("Aufruf: changelog_to_html.py <version> [CHANGELOG.md] [--raw]")
    version = args[0]
    path = args[1] if len(args) > 1 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as fh:
        section = extract_section(fh.read(), version)
    print(section if raw else to_html(section))


if __name__ == "__main__":
    main()
