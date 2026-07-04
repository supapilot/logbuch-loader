# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
und das Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

## [1.1.0] – 2026-07-04

### Geändert
- Auswahl der Lotsenbrüderschaft ist optional: Ohne Auswahl wird das
  Ausbildungsbuch ohne Logo erstellt. Kann ein gewähltes Logo nicht geladen
  werden, wird das Buch trotzdem (ohne Logo) erzeugt.

### Hinzugefügt
- Unit-Tests für Parsing-, Dateinamens- und Revier-Logik sowie eine
  GitHub-Actions-CI (Build + Tests bei jedem Push).

## [1.0.0] – 2026-07-04

Erste öffentliche Version.

### Hinzugefügt
- Anmeldung am BLK Logbuch mit Speicherung der Zugangsdaten im Schlüsselbund.
- Einzel- und Mehrfach-Download von Ausbildungsfahrten als PDF.
- Composer: Zusammenstellen eines vollständigen Ausbildungsbuchs (nach
  § 7 Abs. 1 SeeLAufV) mit Deckblatt, Inhaltsverzeichnis und – optional – dem
  Logo der gewählten Lotsenbrüderschaft.
- Notarisierte, per Developer ID signierte Verteilung als DMG.

[Unveröffentlicht]: https://github.com/supapilot/logbuch-loader/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/supapilot/logbuch-loader/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/supapilot/logbuch-loader/releases/tag/v1.0.0
