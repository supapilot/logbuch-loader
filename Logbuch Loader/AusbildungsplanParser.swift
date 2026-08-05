//
//  AusbildungsplanParser.swift
//  Logbuch Loader
//
//  Liest aus einem eingefügten Ausbildungsplan-PDF, in welchen Monaten die vier
//  Ausbildungsphasen (Coaching Phase, Hafenlotsentörn, Freie Fahrt, Fester Törn)
//  stattfinden, und ordnet die abgelegten Ausbildungsfahrten anhand ihres
//  Datums automatisch der jeweiligen Phase zu.
//
//  Vorgehen (ohne KI, abhängigkeitsfrei):
//   1. PDFKit liefert je Zeichen die Position; daraus werden Zeilen (nach y) und
//      Spalten (nach x) rekonstruiert. Spalte 1 = Phase/„Monat …", Spalte 2 =
//      Monatsangabe, Spalte 3 = Beschreibung.
//   2. Zeilen, deren Spalte 1 ein bekanntes Abschnitts-Label enthält, bilden die
//      Zeilengrenzen. Für jede der vier Zielphasen wird der Spalte-2-Text bis zur
//      nächsten Grenze gesammelt.
//   3. Der Monatstext wird zu Monatsmengen aufgelöst: „/" und Zeilenumbruch =
//      getrennte Gruppen; innerhalb einer Gruppe bilden zwei oder mehr
//      Monatsnamen einen (inklusiven) Bereich – „Februar-April" wie „Februar
//      April" ergeben Feb–Apr.
//
//  Die Zuordnung der Fahrten erfolgt monatsgenau (der Plan gibt nur Monate her).
//  Überlappende Monate (ein Monat in zwei Phasen) werden als Konflikt gemeldet;
//  Monate ohne Phase (z. B. reine Telefonisten-/Wachleiter-Monate) gehen an die
//  zeitlich nächste Phase.
//

import Foundation
import PDFKit
import CoreGraphics

enum AusbildungsplanParser {

    // MARK: - Phasen

    /// Die vier Unterkapitel der Ausbildungsfahrten – in der gewünschten
    /// Reihenfolge im Buch.
    enum Phase: Int, CaseIterable, Identifiable {
        case coaching, hafenlotsentoern, freieFahrt, festerToern
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .coaching:         return "Coaching Phase"
            case .hafenlotsentoern: return "Hafenlotsentörn"
            case .freieFahrt:       return "Freie Fahrt"
            case .festerToern:      return "Fester Törn"
            }
        }

        /// Kleingeschriebene Teilzeichenfolge, an der das Label in Spalte 1
        /// erkannt wird (diakritik-tolerant, vgl. `fold`).
        fileprivate var labelKey: String {
            switch self {
            case .coaching:         return "coaching"
            case .hafenlotsentoern: return "hafenlotsentorn"
            case .freieFahrt:       return "freie fahrt"
            case .festerToern:      return "fester torn"
            }
        }
    }

    /// Weitere Abschnitts-Labels, die zwar keine Zielphase sind, aber als
    /// Zeilengrenze dienen (damit z. B. ein „April" der Telefonisten nicht der
    /// vorherigen Phase zugeschlagen wird). Kontinuationszeilen wie „Monat …"
    /// oder „Fester Fahrlotse" stehen bewusst NICHT hier.
    private static let otherLabels = [
        "telefonist", "wachleiter", "ausguck", "stationsausbildung", "urlaub",
        "prufung", "theorie", "simulator", "ppu", "kanalbereisung",
        "mitglieder", "schiffsfuhrungssimulator",
    ]

    // Layout-Annahmen der A4-Plan-Tabelle: Spalte 1 (Phase/„Monat …") links,
    // Spalte 2 (Monate) in der Mitte, Spalte 3 (Beschreibung) rechts. Die Werte
    // sind Anteile der Seitenbreite (bei A4 ≈ x150 bzw. x248).
    private static let col2Fraction: CGFloat = 0.252
    private static let col3Fraction: CGFloat = 0.417
    /// y-Toleranz (pt), mit der eine Spalte-2-Zeile ihrer Grenze zugeordnet wird.
    private static let boundaryTolerance: CGFloat = 3

    // MARK: - Öffentliche API

    /// Ermittelt für jede im Plan gefundene Zielphase die Kalendermonate (1–12).
    /// Leeres Ergebnis, wenn das PDF nicht lesbar ist oder keine Phase erkannt
    /// wird (dann verhält sich das Buch wie bisher: ein flaches Kapitel).
    static func phaseMonths(inPDF url: URL) -> [Phase: Set<Int>] {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { return [:] }

        // Grenzen und Spalte-2-Text über alle Seiten sammeln (die Pläne sind
        // einseitig, aber mehrseitige schaden nicht).
        var result: [Phase: Set<Int>] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for (phase, months) in phaseMonths(onPage: page) {
                result[phase, default: []].formUnion(months)
            }
        }
        return result
    }

    /// Deutscher Monatsname (für Dialoge).
    static func monthName(_ month: Int) -> String {
        let names = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                     "August", "September", "Oktober", "November", "Dezember"]
        return (1...12).contains(month) ? names[month - 1] : "\(month)"
    }

    /// Monat (1–12) einer Fahrten-PDF aus dem Dateinamen („JJJJ.MM.T … .pdf").
    static func driveMonth(_ url: URL) -> Int? {
        let name = url.lastPathComponent as NSString
        let range = NSRange(location: 0, length: name.length)
        guard let m = driveDateRegex.firstMatch(in: url.lastPathComponent, range: range),
              let month = Int(name.substring(with: m.range(at: 1))) else { return nil }
        return (1...12).contains(month) ? month : nil
    }

    private static let driveDateRegex = try! NSRegularExpression(pattern: #"^\d{4}\.(\d{1,2})\.\d{1,2}"#)

    // MARK: - Zuordnung der Fahrten

    /// Ein noch offener Zuordnungskonflikt: In `month` überschneiden sich mehrere
    /// Phasen; der Anwender muss eine wählen.
    struct MonthConflict: Identifiable {
        let month: Int
        let phases: [Phase]     // Kandidaten in kanonischer Reihenfolge
        let driveCount: Int
        var id: Int { month }
    }

    /// Ergebnis der Zuordnung: Fahrten je Phase (kanonische Reihenfolge) und die
    /// noch offenen Konflikte. Sind Konflikte vorhanden, muss nach deren Auflösung
    /// erneut zugeordnet werden (mit `resolutions`).
    struct Assignment {
        var byPhase: [(phase: Phase, files: [URL])]
        var conflicts: [MonthConflict]
    }

    /// Ordnet die Fahrten den Phasen zu.
    /// - `resolutions`: für zuvor gemeldete Konfliktmonate die gewählte Phase.
    ///
    /// Regeln: genau eine Phase → dorthin; mehrere → Konflikt (oder `resolutions`);
    /// keine → zeitlich nächste Phase. Die Reihenfolge der Fahrten bleibt erhalten
    /// (der Composer sortiert je Unterkapitel chronologisch).
    static func assign(drives: [URL],
                       phaseMonths: [Phase: Set<Int>],
                       resolutions: [Int: Phase] = [:]) -> Assignment {
        let presentPhases = Phase.allCases.filter { !(phaseMonths[$0]?.isEmpty ?? true) }
        guard !presentPhases.isEmpty else {
            return Assignment(byPhase: [], conflicts: [])
        }

        // Monat → Phasen, die diesen Monat abdecken (kanonische Reihenfolge).
        var monthToPhases: [Int: [Phase]] = [:]
        for m in 1...12 {
            let phs = presentPhases.filter { phaseMonths[$0]?.contains(m) ?? false }
            if !phs.isEmpty { monthToPhases[m] = phs }
        }

        // Fahrten nach Monat gruppieren (Reihenfolge je Monat bewahrt).
        var drivesByMonth: [Int: [URL]] = [:]
        var undated: [URL] = []
        for url in drives {
            if let m = driveMonth(url) { drivesByMonth[m, default: []].append(url) }
            else { undated.append(url) }
        }

        var assigned: [Phase: [URL]] = [:]
        var conflicts: [MonthConflict] = []

        for (month, files) in drivesByMonth.sorted(by: { trainingIndex($0.key) < trainingIndex($1.key) }) {
            let phs = monthToPhases[month] ?? []
            switch phs.count {
            case 1:
                assigned[phs[0], default: []].append(contentsOf: files)
            case 0:
                let nearest = nearestPhase(to: month, among: presentPhases, phaseMonths: phaseMonths)
                assigned[nearest, default: []].append(contentsOf: files)
            default:
                if let chosen = resolutions[month], phs.contains(chosen) {
                    assigned[chosen, default: []].append(contentsOf: files)
                } else {
                    conflicts.append(MonthConflict(month: month, phases: phs, driveCount: files.count))
                }
            }
        }
        // Undatierte Fahrten an die erste vorhandene Phase, damit keine verloren geht.
        if !undated.isEmpty { assigned[presentPhases[0], default: []].append(contentsOf: undated) }

        let byPhase = presentPhases.compactMap { phase -> (phase: Phase, files: [URL])? in
            guard let files = assigned[phase], !files.isEmpty else { return nil }
            return (phase: phase, files: files)
        }

        return Assignment(byPhase: byPhase, conflicts: conflicts)
    }

    /// Zeitlich nächste Phase zu `month` (kleinste zyklische Monatsdistanz zu
    /// irgendeinem ihrer Monate; bei Gleichstand die in kanonischer Reihenfolge
    /// frühere Phase).
    private static func nearestPhase(to month: Int, among phases: [Phase],
                                     phaseMonths: [Phase: Set<Int>]) -> Phase {
        func distance(_ phase: Phase) -> Int {
            let months = phaseMonths[phase] ?? []
            return months.map { circularMonthDistance($0, month) }.min() ?? Int.max
        }
        return phases.min { a, b in
            let da = distance(a), db = distance(b)
            if da != db { return da < db }
            return a.rawValue < b.rawValue
        } ?? phases[0]
    }

    /// Zyklische Distanz zweier Kalendermonate (Dezember↔Januar = 1).
    private static func circularMonthDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b)
        return min(d, 12 - d)
    }

    // MARK: - Seiten-Parsing

    /// Trainingsjahr-Index: September = 1 … August = 12 (für Bereichsbildung).
    private static func trainingIndex(_ calendarMonth: Int) -> Int { (calendarMonth - 9 + 12) % 12 + 1 }
    private static func calendarMonth(fromTraining t: Int) -> Int { (t - 1 + 8) % 12 + 1 }

    private static let calendarMonthNames: [String: Int] = [
        "januar": 1, "februar": 2, "marz": 3, "maerz": 3, "april": 4, "mai": 5,
        "juni": 6, "juli": 7, "august": 8, "september": 9, "oktober": 10,
        "november": 11, "dezember": 12,
    ]

    private struct Line { let y: CGFloat; let col1: String; let col2: String }

    private static func phaseMonths(onPage page: PDFPage) -> [Phase: Set<Int>] {
        let lines = extractLines(page)
        guard !lines.isEmpty else { return [:] }

        // Grenzen: Zeilen, deren Spalte 1 ein Ziel- oder sonstiges Label enthält.
        var boundaries: [(y: CGFloat, phase: Phase?)] = []
        for line in lines {
            let folded = fold(line.col1)   // einmal falten, dann mehrfach vergleichen
            if let phase = Phase.allCases.first(where: { folded.contains($0.labelKey) }) {
                boundaries.append((line.y, phase))
            } else if otherLabels.contains(where: { folded.contains($0) }) {
                boundaries.append((line.y, nil))
            }
        }
        boundaries.sort { $0.y < $1.y }
        guard !boundaries.isEmpty else { return [:] }

        // Jede Spalte-2-Zeile der Grenze mit dem größten y ≤ Zeilen-y zuordnen.
        var col2ByBoundary: [Int: [String]] = [:]   // Schlüssel = Grenzindex
        for line in lines where !line.col2.trimmingCharacters(in: .whitespaces).isEmpty {
            // boundaries ist nach y sortiert → die letzte passende ist die Grenze.
            if let i = boundaries.lastIndex(where: { $0.y <= line.y + boundaryTolerance }) {
                col2ByBoundary[i, default: []].append(line.col2)
            }
        }

        var result: [Phase: Set<Int>] = [:]
        for (i, b) in boundaries.enumerated() {
            guard let phase = b.phase else { continue }
            let text = (col2ByBoundary[i] ?? []).joined(separator: " / ")
            let months = parseMonths(text)
            if !months.isEmpty { result[phase, default: []].formUnion(months) }
        }
        return result
    }

    /// Seite in Zeilen zerlegen und je Zeile den Text der Spalten 1 (Phase/„Monat
    /// …") und 2 (Monate) auslesen. Die Zeilenerkennung von PDFKit
    /// (`selectionsByLine`) ist robuster als eine eigene Zeichen-Gruppierung; die
    /// Spalten werden über schmale x-Bänder je Zeile nachselektiert (die dritte,
    /// breite Beschreibungsspalte bleibt außen vor). y wird auf oben-nach-unten
    /// normiert, damit die Grenzenlogik von oben nach unten läuft.
    private static func extractLines(_ page: PDFPage) -> [Line] {
        let bounds = page.bounds(for: .cropBox)
        guard let whole = page.selection(for: bounds) else { return [] }
        let col2X = bounds.minX + bounds.width * col2Fraction
        let col3X = bounds.minX + bounds.width * col3Fraction

        func columnText(_ lineBounds: CGRect, from x0: CGFloat, to x1: CGFloat) -> String {
            let rect = CGRect(x: x0, y: lineBounds.minY, width: x1 - x0, height: lineBounds.height)
            let raw = page.selection(for: rect)?.string ?? ""
            return raw.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [Line] = []
        for lineSel in whole.selectionsByLine() {
            let lb = lineSel.bounds(for: page)
            guard lb.width > 0, lb.height > 0 else { continue }
            let col1 = columnText(lb, from: bounds.minX, to: col2X)
            let col2 = columnText(lb, from: col2X, to: col3X)
            if col1.isEmpty && col2.isEmpty { continue }
            lines.append(Line(y: bounds.maxY - lb.maxY, col1: col1, col2: col2))
        }
        return lines
    }

    /// Monatstext → Kalendermonate. „/" trennt Gruppen; eine Gruppe mit zwei oder
    /// mehr Monatsnamen ergibt den inklusiven Bereich (im Trainingsjahr-Sinn),
    /// eine mit genau einem den einzelnen Monat.
    private static func parseMonths(_ text: String) -> Set<Int> {
        var months: Set<Int> = []
        for group in text.split(separator: "/", omittingEmptySubsequences: false) {
            let found = monthTokens(in: String(group))
            guard !found.isEmpty else { continue }
            if found.count == 1 {
                months.insert(found[0])
            } else {
                let idx = found.map(trainingIndex)
                for t in (idx.min()!)...(idx.max()!) { months.insert(calendarMonth(fromTraining: t)) }
            }
        }
        return months
    }

    /// Kalendermonate der in `text` vorkommenden Monatsnamen, in Reihenfolge.
    private static func monthTokens(in text: String) -> [Int] {
        var result: [Int] = []
        var word = ""
        func commit() {
            if !word.isEmpty {
                if let m = calendarMonthNames[fold(word)] { result.append(m) }
                word = ""
            }
        }
        for ch in text {
            if ch.isLetter { word.append(ch) } else { commit() }
        }
        commit()
        return result
    }

    // MARK: - Text-Normalisierung

    /// Kleinschreibung + Diakritik entfernen (ä→a, ö→o, ü→u, ß→ss) für robuste
    /// Vergleiche.
    private static func fold(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "ß", with: "ss")
        return lowered.folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
    }
}
