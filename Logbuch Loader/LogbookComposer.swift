//
//  LogbookComposer.swift
//  Logbuch Loader
//
//  Baut aus den im Composer abgelegten PDFs ein vollständiges Ausbildungsbuch:
//  Deckblatt, Inhaltsverzeichnis, Kapitel-Deckblätter und die Inhalte – alles
//  auf A4-Hochformat normiert (Querformat wird 90° gegen den Uhrzeigersinn
//  gedreht).
//

import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText

enum LogbookComposer {
    /// A4-Hochformat in Punkten (72 dpi): 210 × 297 mm.
    static let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private static let W = a4.width
    private static let H = a4.height
    private static let leftMargin: CGFloat = 80
    private static let rightMargin = W - leftMargin

    // Dezente Akzentfarben für Deckblatt und Überschriften.
    private static let accentBlue = NSColor(srgbRed: 0.16, green: 0.22, blue: 0.38, alpha: 1)
    private static let accentRed  = NSColor(srgbRed: 0.79, green: 0.27, blue: 0.20, alpha: 1)
    private static let ink       = NSColor(white: 0.13, alpha: 1)
    private static let subtle    = NSColor(white: 0.45, alpha: 1)
    private static let ruleColor = NSColor(white: 0.80, alpha: 1)

    /// Formatiert das Abgabedatum fürs Deckblatt als „TT.MM.JJJJ".
    private static let abgabeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// Das Abgabedatum als „TT.MM.JJJJ" (z. B. „09.07.2026") – gemeinsame Quelle
    /// für die Anzeige im Composer und die Ausgabe auf dem Deckblatt.
    static func abgabeDateString(_ date: Date) -> String { abgabeFormatter.string(from: date) }

    // Inhaltsverzeichnis-Layout (auch für die klickbaren Link-Rechtecke genutzt).
    private static let tocStartY: CGFloat = 360
    private static let tocRowH: CGFloat = 44
    private static let tocFont = NSFont.systemFont(ofSize: 18)

    /// Kapitel: römische Ziffer, Titel (für Inhaltsverzeichnis + Deckblatt) und
    /// die zugehörigen Inhalts-PDFs. Hat ein Kapitel Unterkapitel, sind `files`
    /// leer und die Inhalte liegen in `subchapters`.
    struct Chapter {
        let roman: String
        let title: String
        let files: [URL]
        var subchapters: [Subchapter] = []
    }

    /// Unterkapitel mit eigener Nummer („VI.1"), Deckblatt und Sprungziel.
    struct Subchapter {
        let number: String
        let title: String
        let files: [URL]
    }

    /// Sortierregel für die Dateien eines Kapitels.
    enum SortKind {
        case driveDate      // Ausbildungsfahrten: Datum im Dateinamen
        case simulator      // Simulatorfahrten: Zeitstempel auf der ersten Seite
        case certificate    // Zertifikate: Datum im Dateinamen
        case alphabetical   // alle übrigen: natürlicher Dateiname-Vergleich
    }

    /// Ein Kapitel als Eingabe für `build`: Titel, Dateien und Sortierregel – in
    /// der Reihenfolge, in der die Kapitel im Buch erscheinen sollen.
    struct ChapterInput {
        let title: String
        let files: [URL]
        let sort: SortKind
        /// Optionale Unterkapitel. Sind welche gesetzt, werden `files` ignoriert;
        /// jedes nicht-leere Unterkapitel erhält ein eigenes Deckblatt.
        var subchapters: [SubchapterInput] = []
    }

    /// Ein Unterkapitel als Eingabe für `build`.
    struct SubchapterInput {
        let title: String
        let files: [URL]
    }

    /// Erzeugt das gesamte Ausbildungsbuch als PDF-Daten.
    /// `chapters` in gewünschter Kapitelreihenfolge; leere Kapitel (auch nach
    /// dem Auflösen von ZIPs) werden übersprungen. `logo` ist das zur Laufzeit
    /// geladene Logo der Lotsenbrüderschaft (nil = ohne Logo).
    @MainActor
    static func build(chapters input: [ChapterInput],
                      user: LogbuchUser, submissionDate: Date = Date(),
                      logo: NSImage? = nil, pageNumbers: Bool = true) -> Data? {
        // Temporäres Arbeitsverzeichnis für aus ZIPs entpackte PDFs.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogbuchLoader-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Nur Kapitel mit mindestens einer Datei. ZIP-Dateien werden vorab in
        // ihre enthaltenen PDFs aufgelöst; jedes Kapitel (bzw. Unterkapitel) wird
        // nach seiner Regel sortiert (chronologisch, wo eine Datumslogik greift,
        // sonst alphabetisch). Leere Kapitel/Unterkapitel fallen heraus.
        var sections: [(title: String, files: [URL], subs: [(title: String, files: [URL])])] = []
        for ch in input {
            if ch.subchapters.isEmpty {
                let files = resolvedFiles(ch.files, into: workDir, sort: ch.sort)
                guard !files.isEmpty else { continue }
                sections.append((ch.title, files, []))
            } else {
                var subs: [(title: String, files: [URL])] = []
                for sub in ch.subchapters {
                    let files = resolvedFiles(sub.files, into: workDir, sort: ch.sort)
                    guard !files.isEmpty else { continue }
                    subs.append((sub.title, files))
                }
                guard !subs.isEmpty else { continue }
                sections.append((ch.title, [], subs))
            }
        }

        guard !sections.isEmpty else { return nil }

        // Fortlaufende römische Nummerierung über alle Kapitel hinweg;
        // Unterkapitel erhalten „<roman>.<n>".
        let chapters = sections.enumerated().map { i, s -> Chapter in
            let roman = romanNumeral(i + 1)
            let subchapters = s.subs.enumerated().map { j, sub in
                Subchapter(number: "\(roman).\(j + 1)", title: sub.title, files: sub.files)
            }
            return Chapter(roman: roman, title: s.title, files: s.files, subchapters: subchapters)
        }
        let info = CoverInfo(user: user)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = a4
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        // Zählung beginnt nach Deckblatt und Inhaltsverzeichnis. Die Kapitel-
        // Deckblätter zählen mit (nur ohne sichtbare Nummer); die Seitenzahl wird
        // nur auf den hinzugefügten Inhaltsseiten angezeigt.
        var pageNumber = 0
        drawCoverPage(ctx, info: info, submission: abgabeDateString(submissionDate), logo: logo)
        drawTOCPage(ctx, chapters: chapters, info: info, logo: logo)
        for (index, chapter) in chapters.enumerated() {
            pageNumber += 1   // Kapiteldeckblatt zählt mit (unsichtbar)
            drawChapterDivider(ctx, index: index, chapter: chapter, info: info, logo: logo)
            if chapter.subchapters.isEmpty {
                for url in chapter.files {
                    appendContent(url, ctx: ctx, pageNumber: &pageNumber, pageNumbers: pageNumbers)
                }
            } else {
                for (subIndex, sub) in chapter.subchapters.enumerated() {
                    pageNumber += 1   // Unterkapitel-Deckblatt zählt mit (unsichtbar)
                    drawSubchapterDivider(ctx, chapterIndex: index, subIndex: subIndex,
                                          sub: sub, info: info, logo: logo)
                    for url in sub.files {
                        appendContent(url, ctx: ctx, pageNumber: &pageNumber, pageNumbers: pageNumbers)
                    }
                }
            }
        }

        ctx.closePDF()
        return pdfData as Data
    }

    /// Löst ZIPs auf und sortiert die PDFs nach der Kapitelregel.
    private static func resolvedFiles(_ urls: [URL], into workDir: URL, sort: SortKind) -> [URL] {
        let pdfs = expandArchives(urls, into: workDir)
        switch sort {
        case .driveDate:    return sortedFiles(pdfs, date: driveFileDate)
        case .simulator:    return sortedFiles(pdfs, date: simulatorDate)
        case .certificate:  return sortedFiles(pdfs, date: certificateFileDate)
        case .alphabetical: return sortedFiles(pdfs, date: { _ in nil })
        }
    }

    // MARK: - Dateiname

    /// Schlägt einen Dateinamen vor: „LA3G05 - Ausbildungsbuch Mustermann, Max.pdf".
    /// Stufe und Name stammen aus dem Profil; die Gruppe „Gxx" aus dem Dateinamen
    /// des Ausbildungsplans (`planFirstFile`; entfällt, wenn nicht enthalten).
    static func suggestedFileName(planFirstFile: URL?, user: LogbuchUser) -> String {
        let info = CoverInfo(user: user)
        let prefix = info.laCode + (ausbildungsplanGroup(planFirstFile) ?? "")
        let name = LogbuchService.sanitizeFileName(info.name)
        let base = prefix.isEmpty ? "Ausbildungsbuch \(name)" : "\(prefix) - Ausbildungsbuch \(name)"
        return base + ".pdf"
    }

    private static let planGroupRegexLA  = try! NSRegularExpression(pattern: #"LA\d+(G\d{1,3})"#)
    private static let planGroupRegexStd = try! NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9])(G\d{1,3})(?:[^0-9]|$)"#)

    /// Gruppencode „Gxx" aus dem Dateinamen der ersten Ausbildungsplan-Datei.
    private static func ausbildungsplanGroup(_ planFirstFile: URL?) -> String? {
        guard let first = planFirstFile else { return nil }
        let name = first.lastPathComponent
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = planGroupRegexLA.firstMatch(in: name, range: full) { return ns.substring(with: m.range(at: 1)) }
        if let m = planGroupRegexStd.firstMatch(in: name, range: full) { return ns.substring(with: m.range(at: 1)) }
        return nil
    }

    /// Römische Ziffer für `n` (≥ 1). Deckt beliebig viele Kapitel ab.
    private static func romanNumeral(_ n: Int) -> String {
        let table: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var value = max(n, 1)
        var result = ""
        for (v, r) in table {
            while value >= v { result += r; value -= v }
        }
        return result
    }

    // MARK: - ZIP-Auflösung

    /// Löst Feld-Dateien zu einzelnen PDF-URLs auf (ZIPs entpackt nach `dir`),
    /// ohne Sortierung – für die Vorab-Zuordnung der Ausbildungsfahrten zu
    /// Unterkapiteln. Die zurückgegebenen PDFs müssen bis zum `build`-Aufruf
    /// bestehen bleiben.
    static func expandToPDFs(_ urls: [URL], into dir: URL) -> [URL] {
        expandArchives(urls, into: dir)
    }

    /// Ersetzt ZIP-Dateien durch die enthaltenen PDFs (entpackt nach `dir`); lose
    /// PDFs bleiben unverändert. Andere Dateitypen werden ignoriert.
    private static func expandArchives(_ urls: [URL], into dir: URL) -> [URL] {
        urls.flatMap { url -> [URL] in
            switch url.pathExtension.lowercased() {
            case "pdf": return [url]
            case "zip": return ZipExtractor.extractPDFs(from: url, into: dir)
            default:    return []
            }
        }
    }

    // MARK: - Chronologische Sortierung (Simulatorfahrten)

    /// Sortiert PDFs chronologisch (ältestes zuerst) anhand des per `date`
    /// gelieferten Zeitstempels. Dateien mit Datum stehen vor solchen ohne;
    /// bei gleichem bzw. fehlendem Datum wird alphabetisch (natürlich) nach
    /// Dateiname sortiert. Wird `date` als konstant `nil` übergeben, ergibt sich
    /// eine rein alphabetische Sortierung.
    private static func sortedFiles(_ urls: [URL], date: (URL) -> Date?) -> [URL] {
        urls.map { (url: $0, date: date($0)) }
            .sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (l?, r?):
                    if l != r { return l < r }
                    return naturalLess(lhs.url, rhs.url)
                case (_?, nil):  return true
                case (nil, _?):  return false
                case (nil, nil): return naturalLess(lhs.url, rhs.url)
                }
            }
            .map(\.url)
    }

    /// Natürlicher (alphanumerischer) Dateiname-Vergleich – „(1)" vor „(2)",
    /// „2" vor „10".
    private static func naturalLess(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    private static let driveDateRegex = try! NSRegularExpression(pattern: #"^(\d{4})\.(\d{1,2})\.(\d{1,2})"#)
    private static let isoDateRegex   = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})"#)
    private static let dmyDateRegex   = try! NSRegularExpression(pattern: #"(\d{1,2})\.(\d{1,2})\.(\d{4})"#)
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    /// Datum aus dem Dateinamen der Fahrten-PDFs („JJJJ.MM.T … .pdf", wie vom
    /// Downloader vergeben). Tag-genau – die Reihenfolge mehrerer Fahrten am
    /// selben Tag ergibt sich aus dem natürlichen Dateinamen-Vergleich.
    private static func driveFileDate(_ url: URL) -> Date? {
        firstDate(in: url.lastPathComponent, regex: driveDateRegex, y: 1, m: 2, d: 3)
    }

    /// Datum aus dem Dateinamen eines Zertifikats. Zertifikate sind uneinheitlich
    /// benannt und enthalten im Inhalt oft Fremddaten (z. B. Geburtsdatum), daher
    /// ausschließlich der Dateiname: zuerst ein führendes ISO-Datum „JJJJ-MM-TT",
    /// sonst das erste „T.M.JJJJ" im Namen.
    private static func certificateFileDate(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        return firstDate(in: name, regex: isoDateRegex, y: 1, m: 2, d: 3)
            ?? firstDate(in: name, regex: dmyDateRegex, y: 3, m: 2, d: 1)
    }

    /// Baut aus dem ersten Regex-Treffer in `text` ein Datum; `y`/`m`/`d` sind die
    /// Capture-Gruppen-Indizes für Jahr/Monat/Tag.
    private static func firstDate(in text: String, regex: NSRegularExpression,
                                  y: Int, m: Int, d: Int) -> Date? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let year = Int(ns.substring(with: match.range(at: y))),
              let month = Int(ns.substring(with: match.range(at: m))),
              let day = Int(ns.substring(with: match.range(at: d))) else { return nil }
        return gregorianCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static let simDateRegex = try! NSRegularExpression(pattern: #"\b(\d{2}-[A-Za-z]{3}-\d{2})\b"#)
    private static let simTimeRegex = try! NSRegularExpression(pattern: #"\b(\d{2}-\d{2}-\d{2})\b"#)
    private static let simDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yy-MMM-dd HH-mm-ss"
        return f
    }()

    /// Liest Datum + Uhrzeit aus dem Text der ersten Seite (jeweils erstes
    /// Vorkommen der Tokens), z. B. „25-Oct-10" und „07-54-32".
    private static func simulatorDate(_ url: URL) -> Date? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0),
              let text = page.string else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let dm = simDateRegex.firstMatch(in: text, range: full),
              let tm = simTimeRegex.firstMatch(in: text, range: full) else { return nil }
        let d = ns.substring(with: dm.range(at: 1))
        let t = ns.substring(with: tm.range(at: 1))
        return simDateFormatter.date(from: "\(d) \(t)")
    }

    // MARK: - Deckblatt-Daten

    struct CoverInfo {
        let name: String        // "Nachname, Vorname"
        let abschnitt: String   // "2"
        let laCode: String      // "LA2"
        let laSpaced: String    // "LA 2"
        let zeitraum: String    // "01.03. bis 31.08.2025"

        init(user: LogbuchUser) {
            let parts = user.name.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if parts.count >= 2 {
                name = "\(parts.last!), \(parts.dropLast().joined(separator: " "))"
            } else {
                name = user.name
            }

            let digits = (user.stufe ?? "").filter(\.isNumber)
            abschnitt = digits
            laCode = digits.isEmpty ? (user.stufe ?? "") : "LA\(digits)"
            laSpaced = digits.isEmpty ? laCode : "LA \(digits)"
            zeitraum = Self.zeitraum(forLA: digits)
        }

        /// LA1: 01.09.(VJ) – letzter Februartag; LA2: 01.03. – 31.08.;
        /// LA3: 01.09.(VJ) – 31.08. (Jahr = aktuelles Kalenderjahr).
        private static func zeitraum(forLA digits: String) -> String {
            let cal = Calendar(identifier: .gregorian)
            let year = cal.component(.year, from: Date())
            func lastFeb(_ y: Int) -> Int {
                ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
            }
            switch digits {
            case "1": return "01.09.\(year - 1) bis \(lastFeb(year)).02.\(year)"
            case "2": return "01.03. bis 31.08.\(year)"
            case "3": return "01.09.\(year - 1) bis 31.08.\(year)"
            default:  return ""
            }
        }
    }

    // MARK: - Seiten zeichnen

    private static func drawCoverPage(_ ctx: CGContext, info: CoverInfo, submission: String, logo: NSImage?) {
        ctx.beginPDFPage(nil)
        withAppKit(ctx) {
            drawLogo(logo, top: 120, maxWidth: 360, maxHeight: 150)
            drawCentered("AUSBILDUNGSBUCH", font: .systemFont(ofSize: 30, weight: .semibold),
                         color: accentBlue, y: 300, kern: 1.5)
            rule(centerWidth: 160, y: 348, color: accentRed)
            drawCentered("Lotsenausbildungsabschnitt \(info.abschnitt)",
                         font: .systemFont(ofSize: 18), color: ink, y: 408)
            drawCentered("(\(info.laCode))", font: .systemFont(ofSize: 15), color: subtle, y: 436)
            drawCentered("VORGELEGT VON", font: .systemFont(ofSize: 11, weight: .semibold),
                         color: subtle, y: 524, kern: 1.5)
            drawCentered(info.name, font: .systemFont(ofSize: 19, weight: .bold), color: ink, y: 544)
            drawCentered("am \(submission)", font: .systemFont(ofSize: 15), color: ink, y: 576)
            if !info.zeitraum.isEmpty {
                drawCentered("ZEITRAUM", font: .systemFont(ofSize: 11, weight: .semibold),
                             color: subtle, y: 642, kern: 1.5)
                drawCentered(info.zeitraum, font: .systemFont(ofSize: 17), color: ink, y: 662)
            }
        }
        ctx.endPDFPage()
    }

    /// Ein Inhaltsverzeichnis-Eintrag (Kapitel oder eingerücktes Unterkapitel).
    private struct TOCEntry { let title: String; let number: String; let dest: String; let indent: Bool }

    private static func tocEntries(_ chapters: [Chapter]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for (i, chapter) in chapters.enumerated() {
            entries.append(TOCEntry(title: chapter.title, number: chapter.roman,
                                    dest: "chapter_\(i)", indent: false))
            for (j, sub) in chapter.subchapters.enumerated() {
                entries.append(TOCEntry(title: sub.title, number: sub.number,
                                        dest: "chapter_\(i)_\(j)", indent: true))
            }
        }
        return entries
    }

    private static func drawTOCPage(_ ctx: CGContext, chapters: [Chapter], info: CoverInfo, logo: NSImage?) {
        let entries = tocEntries(chapters)
        // Zeilenhöhe an die Anzahl anpassen, damit auch mit Unterkapiteln alles
        // oberhalb der Fußzeile bleibt.
        let bottomLimit: CGFloat = 720
        let available = bottomLimit - tocStartY
        let rowH = entries.isEmpty ? tocRowH
            : min(tocRowH, available / CGFloat(entries.count))

        ctx.beginPDFPage(nil)
        withAppKit(ctx) {
            drawLogo(logo, top: 40, maxWidth: 220, maxHeight: 90)
            drawCentered("Inhaltsverzeichnis", font: .systemFont(ofSize: 24, weight: .semibold),
                         color: accentBlue, y: 250)
            rule(centerWidth: 180, y: 292, color: accentRed)

            for (i, entry) in entries.enumerated() {
                drawTOCEntry(entry, y: tocStartY + CGFloat(i) * rowH)
            }
            drawFooter(info: info)
        }

        // Klickbare Bereiche je Eintrag → benanntes Ziel
        // (y-up-Koordinaten, da der Flip aus withAppKit bereits zurückgesetzt ist).
        for (i, entry) in entries.enumerated() {
            let yTop = tocStartY + CGFloat(i) * rowH
            let lineH = tocFont.pointSize * 1.3
            let rect = CGRect(x: leftMargin, y: H - (yTop + lineH),
                              width: rightMargin - leftMargin, height: lineH + 6)
            ctx.setDestination(entry.dest as CFString, for: rect)
        }
        ctx.endPDFPage()
    }

    private static func drawChapterDivider(_ ctx: CGContext, index: Int,
                                           chapter: Chapter, info: CoverInfo, logo: NSImage?) {
        ctx.beginPDFPage(nil)
        withAppKit(ctx) {
            drawLogo(logo, top: 40, maxWidth: 220, maxHeight: 90)

            let romanFont = NSFont.systemFont(ofSize: 26, weight: .bold)
            let titleFont = NSFont.systemFont(ofSize: 26, weight: .semibold)
            let roman = NSAttributedString(string: "\(chapter.roman).",
                                           attributes: [.font: romanFont, .foregroundColor: accentRed])
            let title = NSAttributedString(string: chapter.title,
                                           attributes: [.font: titleFont, .foregroundColor: accentBlue])
            let gap: CGFloat = 16
            let total = roman.size().width + gap + title.size().width
            let startX = (W - total) / 2
            let y: CGFloat = 395
            roman.draw(at: CGPoint(x: startX, y: y))
            title.draw(at: CGPoint(x: startX + roman.size().width + gap, y: y))
            ruleX(startX, y + titleFont.pointSize * 1.35, total, color: ruleColor, thickness: 1)

            drawFooter(info: info)
        }

        // Sprungziel für das Inhaltsverzeichnis (oberer Seitenrand).
        ctx.addDestination("chapter_\(index)" as CFString, at: CGPoint(x: 0, y: H))
        ctx.endPDFPage()
    }

    /// Deckblatt eines Unterkapitels – wie das Kapiteldeckblatt, aber etwas
    /// kleiner und mit der Unterkapitel-Nummer („VI.1").
    private static func drawSubchapterDivider(_ ctx: CGContext, chapterIndex: Int, subIndex: Int,
                                              sub: Subchapter, info: CoverInfo, logo: NSImage?) {
        ctx.beginPDFPage(nil)
        withAppKit(ctx) {
            drawLogo(logo, top: 40, maxWidth: 220, maxHeight: 90)

            let numberFont = NSFont.systemFont(ofSize: 22, weight: .bold)
            let titleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
            let number = NSAttributedString(string: sub.number,
                                            attributes: [.font: numberFont, .foregroundColor: accentRed])
            let title = NSAttributedString(string: sub.title,
                                           attributes: [.font: titleFont, .foregroundColor: accentBlue])
            let gap: CGFloat = 14
            let total = number.size().width + gap + title.size().width
            let startX = (W - total) / 2
            let y: CGFloat = 405
            number.draw(at: CGPoint(x: startX, y: y))
            title.draw(at: CGPoint(x: startX + number.size().width + gap, y: y))
            ruleX(startX, y + titleFont.pointSize * 1.35, total, color: ruleColor, thickness: 1)

            drawFooter(info: info)
        }

        // Sprungziel für das Inhaltsverzeichnis (oberer Seitenrand).
        ctx.addDestination("chapter_\(chapterIndex)_\(subIndex)" as CFString, at: CGPoint(x: 0, y: H))
        ctx.endPDFPage()
    }

    // MARK: - Zeichen-Helfer

    /// Richtet ein top-left-Koordinatensystem ein (PDF-Kontext ist y-up) und
    /// aktiviert den AppKit-Zeichenkontext für Text/Bild-Ausgabe.
    private static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body()
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// Zeichnet das (zur Laufzeit geladene) Logo horizontal zentriert am oberen
    /// Rand, skaliert unter Wahrung des Seitenverhältnisses so, dass es in die
    /// Box `maxWidth × maxHeight` passt (nötig, weil die Revier-Logos sehr
    /// unterschiedliche Seitenverhältnisse haben – breit bis quadratisch).
    private static func drawLogo(_ image: NSImage?, top y: CGFloat,
                                 maxWidth: CGFloat, maxHeight: CGFloat) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: CGRect(x: (W - w) / 2, y: y, width: w, height: h))
    }

    private static func drawCentered(_ text: String, font: NSFont,
                                     color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let s = NSAttributedString(string: text, attributes:
            [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern])
        s.draw(in: CGRect(x: 0, y: y, width: W, height: font.pointSize * 1.6))
    }

    /// Mittige horizontale Linie (z. B. Akzentlinie unter Überschriften).
    private static func rule(centerWidth w: CGFloat, y: CGFloat, color: NSColor, thickness: CGFloat = 1.5) {
        ruleX((W - w) / 2, y, w, color: color, thickness: thickness)
    }

    /// Horizontale Linie an fester X-Position.
    private static func ruleX(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, color: NSColor, thickness: CGFloat = 1) {
        color.setFill()
        NSBezierPath(rect: CGRect(x: x, y: y, width: w, height: thickness)).fill()
    }

    /// Eine Inhaltsverzeichnis-Zeile: Titel links, Nummer (Akzentfarbe)
    /// rechtsbündig, dazwischen eine dezente Punktführung. Unterkapitel werden
    /// eingerückt und etwas kleiner/dezenter gesetzt.
    private static func drawTOCEntry(_ entry: TOCEntry, y: CGFloat) {
        let indentX: CGFloat = entry.indent ? 30 : 0
        let leftX = leftMargin + indentX
        let leftFont = entry.indent ? NSFont.systemFont(ofSize: 15) : tocFont
        let rightFont = NSFont.systemFont(ofSize: entry.indent ? 15 : 18, weight: .semibold)
        let leftColor = entry.indent ? subtle : ink
        let rightColor = entry.indent ? subtle : accentBlue

        let leftStr = NSAttributedString(string: entry.title, attributes: [.font: leftFont, .foregroundColor: leftColor])
        let rightStr = NSAttributedString(string: entry.number, attributes:
            [.font: rightFont, .foregroundColor: rightColor])
        leftStr.draw(at: CGPoint(x: leftX, y: y))
        rightStr.draw(at: CGPoint(x: rightMargin - rightStr.size().width, y: y))

        let dotAttrs: [NSAttributedString.Key: Any] = [.font: leftFont, .foregroundColor: ruleColor]
        let dotW = max(NSAttributedString(string: ".", attributes: dotAttrs).size().width, 1)
        let dotsStart = leftX + leftStr.size().width + 6
        let dotsEnd = rightMargin - rightStr.size().width - 8
        if dotsEnd > dotsStart {
            let count = Int((dotsEnd - dotsStart) / dotW)
            if count > 0 {
                NSAttributedString(string: String(repeating: ".", count: count), attributes: dotAttrs)
                    .draw(at: CGPoint(x: dotsStart, y: y + 1))
            }
        }
    }

    /// Dreispaltige Fußzeile mit dünner Trennlinie: Ausbildungsabschnitt |
    /// Ausbildungsbuch | vorgelegt von.
    private static func drawFooter(info: CoverInfo) {
        ruleX(leftMargin, 744, rightMargin - leftMargin, color: ruleColor, thickness: 0.8)
        let label = NSFont.systemFont(ofSize: 10.5)
        let value = NSFont.systemFont(ofSize: 11, weight: .medium)
        let cols: [CGFloat] = [W * 0.22, W * 0.5, W * 0.78]

        func centered(_ text: String, colX: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            s.draw(at: CGPoint(x: colX - s.size().width / 2, y: y))
        }
        centered("Ausbildungsabschnitt", colX: cols[0], y: 754, font: label, color: subtle)
        centered(info.laSpaced, colX: cols[0], y: 770, font: value, color: ink)
        centered("Ausbildungsbuch", colX: cols[1], y: 754, font: label, color: subtle)
        centered("vorgelegt von", colX: cols[2], y: 754, font: label, color: subtle)
        centered(info.name, colX: cols[2], y: 770, font: value, color: ink)
    }

    // MARK: - Inhalts-Seiten (A4-normiert)

    private static func appendContent(_ url: URL, ctx: CGContext, pageNumber: inout Int, pageNumbers: Bool) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return }
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            pageNumber += 1
            drawPageOntoA4(page, in: ctx, pageNumber: pageNumber, showPageNumber: pageNumbers)
        }
    }

    /// Zeichnet eine Quellseite größengerecht und zentriert auf A4-Hochformat
    /// und setzt unten rechts die Seitenzahl. Querformat wird um 90° gegen den
    /// Uhrzeigersinn gedreht.
    private static func drawPageOntoA4(_ page: CGPDFPage, in ctx: CGContext, pageNumber: Int,
                                       showPageNumber: Bool) {
        let box = page.getBoxRect(.cropBox)
        let intrinsic = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotated90 = intrinsic == 90 || intrinsic == 270
        let displayWidth = rotated90 ? box.height : box.width
        let displayHeight = rotated90 ? box.width : box.height
        let isLandscape = displayWidth > displayHeight
        let extraRotation: Int32 = isLandscape ? -90 : 0

        ctx.beginPDFPage(nil)
        ctx.saveGState()
        let transform = page.getDrawingTransform(.cropBox, rect: a4,
                                                 rotate: extraRotation, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        if showPageNumber { drawPageNumber(ctx, pageNumber, landscape: isLandscape) }
        ctx.endPDFPage()
    }

    private static let pageNumberAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: ink,
    ]

    /// Seitenzahl im gedämpften Fußzeilen-Stil. Hochformat: unten rechts auf dem
    /// Blatt. Querformat (Inhalt ist um 90° gegen den Uhrzeigersinn gedreht
    /// eingebettet): die Zahl **ebenso um 90° gegen den Uhrzeigersinn gedreht**,
    /// sodass sie zur Textausrichtung der Seite passt, in der unteren rechten Ecke
    /// der Querformat-Ansicht – physisch die obere rechte Ecke des Hochformat-Blatts.
    private static func drawPageNumber(_ ctx: CGContext, _ number: Int, landscape: Bool) {
        let s = NSAttributedString(string: "\(number)", attributes: pageNumberAttrs)
        guard landscape else {
            withAppKit(ctx) {
                s.draw(at: CGPoint(x: W - 34 - s.size().width, y: H - 32))
            }
            return
        }
        let line = CTLineCreateWithAttributedString(s)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        ctx.translateBy(x: W - 26, y: H - 34 - w)   // obere rechte Ecke; Text läuft nach oben
        ctx.rotate(by: .pi / 2)                     // +90° gegen den Uhrzeigersinn
        // Text-Matrix zurücksetzen: die vorherige Seite (z. B. das per AppKit in
        // gespiegeltem Kontext gezeichnete Kapitel-Deckblatt) hinterlässt eine
        // gespiegelte Text-Matrix, die von saveGState/restoreGState NICHT erfasst
        // wird. Ohne dies würde die erste Querformat-Seite entgegengesetzt gedreht.
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
