# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
und das Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

## [1.3.0] – 2026-07-08

### Hinzugefügt
- **Kapitel frei anordnen:** Halte ein Drag-&-Drop-Feld gedrückt und ziehe es an
  eine andere Position – die Felder ordnen sich wie App-Symbole neu an. Die
  Reihenfolge der Felder bestimmt direkt die Kapitelreihenfolge im
  Ausbildungsbuch. Alle Felder (Standard- wie eigene Kapitel) sind verschiebbar.

## [1.2.1] – 2026-07-08

### Hinzugefügt
- **Eigene Kapitel im Composer:** Über den „+"-Button unter „Unterlagen" lassen
  sich bis zu drei zusätzliche Kapitel mit frei wählbarem Namen anlegen. Sie
  erhalten eigene Drag-&-Drop-Felder und erscheinen im Ausbildungsbuch nach
  „Zertifikate". Leer gelassene Kapitel werden – wie leere Standardfelder – nicht
  aufgenommen.

### Geändert
- Pro Feld kann nur noch eine ZIP-Datei abgelegt werden (mehrere lose PDFs bzw.
  ein Ordner bleiben möglich).

### Sicherheit
- Zugangsdaten im Schlüsselbund nutzen jetzt `WhenUnlocked` (restriktiver als
  bisher `AfterFirstUnlock`).
- Heruntergeladene Dateien werden vor dem Speichern auf eine gültige
  PDF-Signatur geprüft (fängt z. B. HTML-Fehlerseiten mit Status 200 ab).
- Der ZIP-Entpacker begrenzt Archivgröße, Dateizahl sowie Einzel- und
  Gesamtgröße, um manipulierte Archive („ZIP-Bomben") abzuwehren.
- `SECURITY.md` mit Meldeweg für Sicherheitslücken ergänzt.

## [1.2.0] – 2026-07-08

### Hinzugefügt
- In die Drag-&-Drop-Felder des Composers lassen sich jetzt auch **ganze
  Ordner** ziehen (oder per Klick auswählen). Der Ordner wird nach passenden
  PDF-/ZIP-Dateien durchsucht und alle werden übernommen – das erspart das
  einzelne Hineinziehen dutzender Dateien. Bereits vorhandene Dateien werden
  dabei nicht doppelt hinzugefügt.

## [1.1.1] – 2026-07-06

### Behoben
- App startete auf Intel-Macs mit älterem macOS nicht („…wird auf diesem Mac
  nicht unterstützt"). Ursache war eine zu hohe Hardened-Runtime-Version aus dem
  Build-SDK. Die Signatur ist jetzt fest auf macOS 14.0 als Mindest-Runtime
  gesetzt, sodass die App auf allen Macs ab macOS 14.0 läuft (Intel und Apple
  Silicon).

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

[Unveröffentlicht]: https://github.com/supapilot/logbuch-loader/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/supapilot/logbuch-loader/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/supapilot/logbuch-loader/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/supapilot/logbuch-loader/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/supapilot/logbuch-loader/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/supapilot/logbuch-loader/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/supapilot/logbuch-loader/releases/tag/v1.0.0
