//
//  AusbildungsverlaufBuilder.swift
//  Logbuch Loader
//
//  Verarbeitet eine ins Feld „Ausbildungsverlauf" gelegte XLSX-Masterliste:
//  gleicht den Profilnamen mit Spalte A ab (fuzzy, ohne KI), behält nur die
//  Zeilen des Anwärters und rendert daraus ein zweiseitiges Querformat-PDF
//  (Sep–Feb / Mär–Aug), farblich an die Ausbildungsbuch-Vorlage angelehnt.
//  Die Eintragsfarben stammen unverändert aus der XLSX.
//
//  Der XLSX-Reader ist ein minimaler, abhängigkeitsfreier Parser (XLSX = ZIP aus
//  XML-Teilen), der genau die benötigten Teile liest: SharedStrings, das erste
//  Arbeitsblatt, Styles (Füllfarben) und das Theme (zur Auflösung von
//  Theme-Farben). Reicht bewusst nur so weit, wie diese Aufgabe es verlangt.
//

import Foundation
import AppKit
import CoreGraphics
import CoreText

enum AusbildungsverlaufBuilder {

    enum BuildError: Error { case unreadable, noNames, noEntries, renderFailed }

    // MARK: - Öffentliche API

    /// Distinkte Namen aus Spalte A – Kandidaten für den Namensabgleich.
    static func candidateNames(inXLSX url: URL) throws -> [String] {
        let names = try loadWorkbook(url).distinctColumnANames()
        guard !names.isEmpty else { throw BuildError.noNames }
        return names
    }

    /// Bester Treffer eines Profilnamens im Kandidatenset (fuzzy, ohne KI).
    /// `score` ∈ [0,1]; `margin` ist der Abstand zum zweitbesten Treffer.
    static func bestMatch(profile: String, candidates: [String]) -> (name: String, score: Double, margin: Double)? {
        let scored = candidates
            .map { (name: $0, score: NameMatch.similarity(profile, $0)) }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return nil }
        let margin = best.score - (scored.count > 1 ? scored[1].score : 0)
        return (best.name, best.score, margin)
    }

    /// Schwelle/Abstand, ab denen ein Treffer als eindeutig gilt (Sicherheitsnetz:
    /// darunter fragt die UI nach, statt still die falschen Zeilen zu entfernen).
    static func isConfident(score: Double, margin: Double) -> Bool {
        score >= 0.80 && margin >= 0.12
    }

    /// Erzeugt das gefilterte zweiseitige PDF für `targetName` und legt es unter
    /// `dir` als „Ausbildungsverlauf.pdf" ab. Gibt die Ziel-URL zurück.
    static func buildPDF(fromXLSX url: URL, targetName: String, into dir: URL) throws -> URL {
        let wb = try loadWorkbook(url)
        let months = wb.months(forName: targetName)
        // Kein Monatsblock gefunden (z. B. unerwartetes Tabellenformat oder Name
        // ohne Kalendereintrag) → sauber abbrechen statt leeres PDF erzeugen.
        guard !months.isEmpty else { throw BuildError.noEntries }
        guard let data = Renderer.render(months: months) else { throw BuildError.renderFailed }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Ausbildungsverlauf.pdf")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - Laden

    private static func loadWorkbook(_ url: URL) throws -> Workbook {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { throw BuildError.unreadable }
        let entries = ZipExtractor.readEntries(from: raw) { name in
            name == "xl/sharedStrings.xml" || name == "xl/styles.xml"
                || name == "xl/theme/theme1.xml"
                || name.hasPrefix("xl/worksheets/sheet")
        }
        // Erstes Arbeitsblatt (sheet1.xml bzw. das alphabetisch erste vorhandene).
        guard let sheetName = entries.keys
            .filter({ $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") })
            .sorted().first,
            let sheetData = entries[sheetName] else { throw BuildError.unreadable }

        let shared = entries["xl/sharedStrings.xml"].map(SharedStringsParser.parse) ?? []
        let styles = entries["xl/styles.xml"].map(StylesParser.parse) ?? StylesParser.Result(cellFillIDs: [], fills: [])
        let theme  = entries["xl/theme/theme1.xml"].map(ThemeParser.parse) ?? []
        let sheet  = SheetParser.parse(sheetData, sharedStrings: shared)
        return Workbook(sheet: sheet, styles: styles, theme: theme)
    }
}

// MARK: - Namensabgleich (ohne KI)

enum NameMatch {
    /// Normalisiert: Kleinschreibung, Diakritika falten (ä→a, ö→o, ü→u, ß→ss),
    /// Satzzeichen zu Leerzeichen, Mehrfach-Leerzeichen zusammenfassen.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "ß", with: "ss")
        t = t.folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
        let mapped = t.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    /// Ähnlichkeit ∈ [0,1] zwischen Profilname und Kandidat. Kombiniert
    /// Token-Abdeckung (jeder Kandidaten-Token muss einem Profil-Token ähneln;
    /// überzählige Profil-Token wie Mittelnamen bleiben straffrei) mit einem
    /// Kompaktvergleich ohne Leerzeichen (fängt fehlende/zusätzliche Spaces ab).
    static func similarity(_ profile: String, _ candidate: String) -> Double {
        let p = tokens(profile), c = tokens(candidate)
        guard !p.isEmpty, !c.isEmpty else { return 0 }

        // Token-Abdeckung: mittlere Bestähnlichkeit jedes Kandidaten-Tokens zu
        // irgendeinem Profil-Token (tolerant gegen Tippfehler via Edit-Distanz).
        var sum = 0.0
        for ct in c {
            let best = p.map { ratio(ct, $0) }.max() ?? 0
            sum += best
        }
        let coverage = sum / Double(c.count)

        // Kompaktvergleich der zusammengefügten Tokens (Space-Unabhängigkeit).
        let compact = ratio(p.joined(), c.joined())

        return max(coverage, compact)
    }

    /// Ähnlichkeit zweier Wörter aus der Levenshtein-Distanz: 1 − dist/maxLen.
    static func ratio(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

// MARK: - Workbook-Modell + Monatsauszug

private struct Workbook {
    let sheet: SheetParser.Sheet
    let styles: StylesParser.Result
    let theme: [String]     // clrScheme in Reihenfolge dk1,lt1,dk2,lt2,accent1..6,hlink,folHlink

    /// Aufgelöste Theme-Palette (Excel-Swap 0↔1, 2↔3).
    private var palette: [String] {
        guard theme.count >= 12 else { return theme }
        var t = theme
        t.swapAt(0, 1); t.swapAt(2, 3)
        return t
    }

    /// Distinkte, nicht-leere Werte aus Spalte A (in stabiler Reihenfolge).
    func distinctColumnANames() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for row in sheet.rows.keys.sorted() {
            guard let v = sheet.value(row, 1), !v.isEmpty else { continue }
            if seen.insert(v).inserted { out.append(v) }
        }
        return out
    }

    /// Baut die Monate für `name`: je Monatsblock die Tages-/Wochentagszeile und
    /// die Eintragszeile des Anwärters (Wert + Farbe + horizontale Merges).
    func months(forName name: String) -> [Renderer.Month] {
        let dayRows = sheet.rows.keys.filter { isDayRow($0) }.sorted()
        // Zeilen des Anwärters (Spalte A == name).
        let targetRows = sheet.rows.keys.filter { sheet.value($0, 1) == name }.sorted()

        var months: [Renderer.Month] = []
        for entryRow in targetRows {
            guard let dayRow = dayRows.last(where: { $0 < entryRow }) else { continue }
            let weekdayRow = dayRow + 1
            let dayCols = (3...maxCol).filter { isDayNumber(sheet.value(dayRow, $0)) }
            let merges = sheet.horizontalMerges(inRow: entryRow)   // startCol -> endCol
            var covered = Set<Int>()
            for (s, e) in merges where e > s { for x in (s + 1)...e { covered.insert(x) } }

            var days: [Renderer.Day] = []
            for col in dayCols {
                let num = (sheet.value(dayRow, col) ?? "").replacingOccurrences(of: ".", with: "")
                let wd = sheet.value(weekdayRow, col) ?? ""
                let val = sheet.value(entryRow, col) ?? ""
                let span = (merges[col].map { $0 - col + 1 }) ?? 1
                days.append(Renderer.Day(num: num, wd: wd, value: val,
                                         fillHex: fillHex(entryRow, col),
                                         span: span, skip: covered.contains(col)))
            }
            months.append(Renderer.Month(name: monthLabel(near: dayRow), days: days))
        }
        return months
    }

    // MARK: Ableitungen

    private var maxCol: Int { sheet.maxCol }

    private func isDayRow(_ row: Int) -> Bool { sheet.value(row, 3) == "1." }

    private func isDayNumber(_ v: String?) -> Bool {
        guard let v, v.hasSuffix("."), v.count >= 2 else { return false }
        return v.dropLast().allSatisfy(\.isNumber)
    }

    private static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni",
                                     "Juli", "August", "September", "Oktober", "November", "Dezember"]

    /// Monatsname aus einer der Zeilen dicht über der Tageszeile.
    private func monthLabel(near dayRow: Int) -> String {
        for row in max(1, dayRow - 4)..<dayRow {
            for col in 1...maxCol {
                guard let v = sheet.value(row, col) else { continue }
                for m in Self.monthNames where v.contains(m) { return m }
            }
        }
        return ""
    }

    /// Löst die Füllfarbe einer Zelle als „RRGGBB" auf (nil = keine/weiß).
    private func fillHex(_ row: Int, _ col: Int) -> String? {
        let styleIndex = sheet.style(row, col)
        guard styleIndex < styles.cellFillIDs.count else { return nil }
        let fillID = styles.cellFillIDs[styleIndex]
        guard fillID < styles.fills.count else { return nil }
        let fill = styles.fills[fillID]
        guard fill.patternType == "solid" else { return nil }
        if let rgb = fill.rgb {
            let hex = String(rgb.suffix(6)).uppercased()
            return hex == "FFFFFF" ? nil : hex
        }
        if let theme = fill.theme, theme >= 0, theme < palette.count {
            return applyTint(palette[theme], fill.tint ?? 0)
        }
        return nil
    }

    /// Linearer Tint (OOXML-Näherung): tint<0 dunkelt, tint>0 hellt auf.
    private func applyTint(_ hex: String, _ tint: Double) -> String {
        func comp(_ x: Int) -> Int {
            let d = Double(x)
            let v = tint < 0 ? d * (1 + tint) : d * (1 - tint) + 255 * tint
            return max(0, min(255, Int(v.rounded())))
        }
        guard hex.count == 6,
              let r = Int(hex.prefix(2), radix: 16),
              let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
              let b = Int(hex.suffix(2), radix: 16) else { return hex }
        return String(format: "%02X%02X%02X", comp(r), comp(g), comp(b))
    }
}

// MARK: - XLSX-Teilparser (XMLParser-basiert)

/// SharedStrings: jeder <si> wird zu einem String (alle enthaltenen <t> verkettet).
private enum SharedStringsParser {
    static func parse(_ data: Data) -> [String] {
        let d = Delegate(); let p = XMLParser(data: data); p.delegate = d; p.parse(); return d.strings
    }
    private final class Delegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var inSI = false, inT = false, buffer = ""
        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if el == "si" { inSI = true; buffer = "" }
            else if el == "t" && inSI { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { buffer += s } }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            if el == "t" { inT = false }
            else if el == "si" { strings.append(buffer); inSI = false }
        }
    }
}

/// Arbeitsblatt: Zellwerte (nach SharedStrings aufgelöst), Stil-Index je Zelle,
/// horizontale verbundene Zellen.
private enum SheetParser {
    struct Cell { let value: String; let style: Int }
    struct Sheet {
        var rows: [Int: [Int: Cell]] = [:]
        var maxCol = 1
        var merges: [(row: Int, c1: Int, c2: Int)] = []
        func value(_ row: Int, _ col: Int) -> String? { rows[row]?[col]?.value }
        func style(_ row: Int, _ col: Int) -> Int { rows[row]?[col]?.style ?? 0 }
        func horizontalMerges(inRow row: Int) -> [Int: Int] {
            var m: [Int: Int] = [:]
            for mr in merges where mr.row == row && mr.c2 > mr.c1 { m[mr.c1] = mr.c2 }
            return m
        }
    }

    static func parse(_ data: Data, sharedStrings: [String]) -> Sheet {
        let d = Delegate(shared: sharedStrings)
        let p = XMLParser(data: data); p.delegate = d; p.parse(); return d.sheet
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let shared: [String]
        var sheet = Sheet()
        private var curRow = 0, curCol = 0, curStyle = 0, curType = ""
        private var vBuf = "", tBuf = "", inV = false, inT = false
        init(shared: [String]) { self.shared = shared }

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            switch el {
            case "row":
                curRow = Int(a["r"] ?? "") ?? (curRow + 1)
            case "c":
                let ref = a["r"] ?? ""
                curCol = SheetParser.column(fromRef: ref)
                curStyle = Int(a["s"] ?? "0") ?? 0
                curType = a["t"] ?? ""
                vBuf = ""; tBuf = ""
            case "v": inV = true
            case "t": inT = true
            case "mergeCell":
                if let ref = a["ref"], let (r, c1, c2) = SheetParser.horizontalMerge(ref) {
                    sheet.merges.append((r, c1, c2))
                }
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inV { vBuf += s } else if inT { tBuf += s }
        }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "v": inV = false
            case "t": inT = false
            case "c":
                let value: String
                switch curType {
                case "s":  value = (Int(vBuf).flatMap { $0 < shared.count ? shared[$0] : nil }) ?? ""
                case "inlineStr", "str": value = tBuf.isEmpty ? vBuf : tBuf
                default:   value = vBuf
                }
                if !value.isEmpty && curCol > 0 {
                    sheet.rows[curRow, default: [:]][curCol] = Cell(value: value, style: curStyle)
                    sheet.maxCol = max(sheet.maxCol, curCol)
                }
            default: break
            }
        }
    }

    /// Spaltenindex (1-basiert, A=1) aus einer Zelladresse wie „AB12".
    static func column(fromRef ref: String) -> Int {
        var col = 0
        for ch in ref {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break } // A–Z
            col = col * 26 + Int(a - 64)
        }
        return col
    }

    /// Zerlegt „X9:Y9" in (Zeile, StartSpalte, EndSpalte) – nur wenn beide in
    /// derselben Zeile liegen (horizontaler Merge).
    static func horizontalMerge(_ ref: String) -> (Int, Int, Int)? {
        let parts = ref.split(separator: ":")
        guard parts.count == 2,
              let (c1, r1) = cell(String(parts[0])), let (c2, r2) = cell(String(parts[1])),
              r1 == r2 else { return nil }
        return (r1, min(c1, c2), max(c1, c2))
    }
    private static func cell(_ ref: String) -> (col: Int, row: Int)? {
        let col = column(fromRef: ref)
        let digits = ref.drop { $0.isLetter }
        guard col > 0, let row = Int(digits) else { return nil }
        return (col, row)
    }
}

/// Styles: Fill-ID je Zellformat (cellXfs) und die Füllungen (Muster + fgColor).
private enum StylesParser {
    struct Fill { let patternType: String?; let rgb: String?; let theme: Int?; let tint: Double? }
    struct Result { let cellFillIDs: [Int]; let fills: [Fill] }

    static func parse(_ data: Data) -> Result {
        let d = Delegate(); let p = XMLParser(data: data); p.delegate = d; p.parse()
        return Result(cellFillIDs: d.cellFillIDs, fills: d.fills)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var fills: [Fill] = []
        var cellFillIDs: [Int] = []
        private var inFills = false, inCellXfs = false
        private var curPattern: String?, curRGB: String?, curTheme: Int?, curTint: Double?

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            switch el {
            case "fills":   inFills = true
            case "cellXfs": inCellXfs = true
            case "fill" where inFills:
                curPattern = nil; curRGB = nil; curTheme = nil; curTint = nil
            case "patternFill" where inFills:
                curPattern = a["patternType"]
            case "fgColor" where inFills:
                curRGB = a["rgb"]
                curTheme = a["theme"].flatMap { Int($0) }
                curTint = a["tint"].flatMap { Double($0) }
            case "xf" where inCellXfs:
                cellFillIDs.append(Int(a["fillId"] ?? "0") ?? 0)
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "fills":   inFills = false
            case "cellXfs": inCellXfs = false
            case "fill" where inFills:
                fills.append(Fill(patternType: curPattern, rgb: curRGB, theme: curTheme, tint: curTint))
            default: break
            }
        }
    }
}

/// Theme: die zwölf Farben des clrScheme in Definitionsreihenfolge
/// (dk1, lt1, dk2, lt2, accent1…6, hlink, folHlink) als „RRGGBB".
private enum ThemeParser {
    static func parse(_ data: Data) -> [String] {
        let d = Delegate(); let p = XMLParser(data: data); p.delegate = d; p.parse()
        let order = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
                     "accent4", "accent5", "accent6", "hlink", "folHlink"]
        return order.compactMap { d.colors[$0] }
    }
    private final class Delegate: NSObject, XMLParserDelegate {
        var colors: [String: String] = [:]
        private var inScheme = false, curKey: String?
        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            let name = el.hasPrefix("a:") ? String(el.dropFirst(2)) : el
            if name == "clrScheme" { inScheme = true; return }
            guard inScheme else { return }
            switch name {
            case "srgbClr": if let key = curKey, let v = a["val"] { colors[key] = v.uppercased() }
            case "sysClr":  if let key = curKey, let v = a["lastClr"] { colors[key] = v.uppercased() }
            default: curKey = name       // dk1, lt1, accent1 …
            }
        }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let name = el.hasPrefix("a:") ? String(el.dropFirst(2)) : el
            if name == "clrScheme" { inScheme = false }
        }
    }
}

// MARK: - Renderer (zweiseitiges Querformat-PDF)

enum Renderer {
    struct Day { let num: String; let wd: String; let value: String; let fillHex: String?; let span: Int; let skip: Bool }
    struct Month { let name: String; let days: [Day] }

    // A4 quer in Punkten (72 dpi).
    private static let PW: CGFloat = 841.89
    private static let PH: CGFloat = 595.28
    // Ränder rundum großzügig (auf allen Seiten nochmals ~50% vergrößert).
    private static let ML: CGFloat = 63, MR: CGFloat = 63, MT: CGFloat = 39, MB: CGFloat = 40.5
    private static let nDays = 31

    // Palette der Ausbildungsbuch-Vorlage (siehe LogbookComposer).
    private static let dark = NSColor(srgbRed: 0.16, green: 0.22, blue: 0.38, alpha: 1)   // accentBlue
    private static let accent = NSColor(srgbRed: 0.79, green: 0.27, blue: 0.20, alpha: 1) // accentRed
    private static let ink = NSColor(white: 0.13, alpha: 1)
    private static let subtle = NSColor(white: 0.45, alpha: 1)
    private static let grid = NSColor(white: 0.80, alpha: 1)
    private static let weekend = NSColor(srgbRed: 0.933, green: 0.937, blue: 0.949, alpha: 1)
    private static let white = NSColor.white

    static func render(months: [Month]) -> Data? {
        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: PW, height: PH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        drawPage(ctx, Array(months.prefix(6)))
        drawPage(ctx, Array(months.dropFirst(6).prefix(6)))
        ctx.closePDF()
        return pdf as Data
    }

    private enum RowKind { case month, spacer, days, weekday, entry, gap }

    // Eine Seite: bis zu sechs Monate, gewichtete Zeilen exakt auf die Seitenhöhe skaliert.
    private static func drawPage(_ ctx: CGContext, _ chunk: [Month]) {
        ctx.beginPDFPage(nil)

        drawText(ctx, "Ausbildungsverlauf", x: ML, baseline: PH - MT + 4,
                 font: .systemFont(ofSize: 11, weight: .bold), color: ink, align: .left)

        var rows: [(RowKind, CGFloat, Month?)] = []
        for (i, m) in chunk.enumerated() {
            rows += [(.month, 2, m), (.spacer, 1, nil), (.days, 1, m),
                     (.weekday, 1, m), (.spacer, 1, nil), (.entry, 2, m)]
            if i < chunk.count - 1 { rows.append((.gap, 2, nil)) }
        }
        guard !rows.isEmpty else { ctx.endPDFPage(); return }

        let usable = PH - MT - MB - 16
        let unit = usable / rows.map(\.1).reduce(0, +)
        let colW = (PW - ML - MR) / CGFloat(nDays)
        var y = PH - MT - 16

        for (kind, weight, month) in rows {
            let rh = unit * weight
            y -= rh
            switch kind {
            case .spacer, .gap:
                break
            case .month:
                fill(ctx, CGRect(x: ML, y: y, width: PW - ML - MR, height: rh), dark)
                let fs = min(13, rh * 0.6)
                drawText(ctx, month?.name ?? "", x: PW / 2, baseline: y + rh / 2 - fs * 0.35,
                         font: .systemFont(ofSize: fs, weight: .bold), color: white, align: .center)
            case .days, .weekday, .entry:
                drawGridRow(ctx, kind: kind, month: month, y: y, rh: rh, colW: colW)
            }
        }
        ctx.endPDFPage()
    }

    private static func drawGridRow(_ ctx: CGContext, kind: RowKind, month: Month?, y: CGFloat, rh: CGFloat, colW: CGFloat) {
        guard let month else { return }
        for i in 0..<nDays {
            let cx = ML + CGFloat(i) * colW
            let day = i < month.days.count ? month.days[i] : nil
            let isWeekend = day.map { $0.wd == "Sa" || $0.wd == "So" } ?? false

            if kind == .entry {
                drawEntryCell(ctx, day: day, isWeekend: isWeekend, cx: cx, y: y, rh: rh, colW: colW)
                continue
            }
            // Tag- bzw. Wochentagszeile
            if isWeekend { fill(ctx, CGRect(x: cx, y: y, width: colW, height: rh), weekend) }
            stroke(ctx, CGRect(x: cx, y: y, width: colW, height: rh))
            guard let day else { continue }
            if kind == .days {
                drawText(ctx, day.num, x: cx + colW / 2, baseline: y + rh / 2 - 2.3,
                         font: .systemFont(ofSize: 6.5, weight: .bold), color: ink, align: .center)
            } else {
                drawText(ctx, day.wd, x: cx + colW / 2, baseline: y + rh / 2 - 2,
                         font: .systemFont(ofSize: 5.8), color: isWeekend ? accent : subtle, align: .center)
            }
        }
    }

    private static func drawEntryCell(_ ctx: CGContext, day: Day?, isWeekend: Bool,
                                      cx: CGFloat, y: CGFloat, rh: CGFloat, colW: CGFloat) {
        guard let day else {
            stroke(ctx, CGRect(x: cx, y: y, width: colW, height: rh)); return
        }
        if day.skip { return }
        let w = colW * CGFloat(day.span)
        let rect = CGRect(x: cx, y: y, width: w, height: rh)
        if let hex = day.fillHex, let color = NSColor(hex: hex) {
            fill(ctx, rect, color)
        } else if isWeekend {
            fill(ctx, rect, weekend)
        }
        stroke(ctx, rect)
        guard !day.value.isEmpty else { return }
        let pad: CGFloat = 1.6
        let (lines, fs) = fitLines(day.value, maxWidth: w - 2 * pad, maxHeight: rh - 2)
        let textColor = day.fillHex.flatMap { NSColor(hex: $0) }.map(contrastColor) ?? ink
        let lineH = fs * 1.05
        var ty = y + rh / 2 + CGFloat(lines.count) * lineH / 2 - fs * 0.95
        for ln in lines {
            drawText(ctx, ln, x: cx + w / 2, baseline: ty, font: .systemFont(ofSize: fs), color: textColor, align: .center)
            ty -= lineH
        }
    }

    // MARK: Zeichen-Primitive

    private enum Align { case left, center }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.fill(rect)
    }
    private static func stroke(_ ctx: CGContext, _ rect: CGRect) {
        ctx.setStrokeColor(grid.cgColor); ctx.setLineWidth(0.3); ctx.stroke(rect)
    }

    private static func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, baseline y: CGFloat,
                                 font: NSFont, color: NSColor, align: Align) {
        guard !text.isEmpty else { return }
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: align == .center ? x - w / 2 : x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Bricht auf `maxWidth` um; überlange Einzelwörter werden hart mit „-" getrennt.
    private static func wrap(_ text: String, maxWidth: CGFloat, fontSize fs: CGFloat) -> [String] {
        let font = NSFont.systemFont(ofSize: fs)
        var lines: [String] = []; var cur = ""
        func flush() { if !cur.isEmpty { lines.append(cur); cur = "" } }
        for word in text.split(separator: " ").map(String.init) {
            if width(word, font: font) > maxWidth {
                flush()
                for piece in breakWord(word, maxWidth: maxWidth, font: font) {
                    if piece.hasSuffix("-") { lines.append(piece) } else { cur = piece }
                }
                continue
            }
            let candidate = cur.isEmpty ? word : cur + " " + word
            if width(candidate, font: font) <= maxWidth || cur.isEmpty { cur = candidate }
            else { lines.append(cur); cur = word }
        }
        flush()
        return lines
    }

    private static func breakWord(_ word: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        var out: [String] = []; var cur = ""
        for ch in word {
            let t = cur + String(ch)
            if width(t + "-", font: font) <= maxWidth || cur.isEmpty { cur = t }
            else { out.append(cur + "-"); cur = String(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Verkleinert die Schrift, bis der Text in Breite und Höhe passt.
    private static func fitLines(_ text: String, maxWidth: CGFloat, maxHeight: CGFloat) -> (lines: [String], fs: CGFloat) {
        for fs in [5.4, 5.0, 4.6, 4.2, 3.9] as [CGFloat] {
            let lines = wrap(text, maxWidth: maxWidth, fontSize: fs)
            if CGFloat(lines.count) * fs * 1.05 <= maxHeight { return (lines, fs) }
        }
        return (wrap(text, maxWidth: maxWidth, fontSize: 3.9), 3.9)
    }

    /// Schwarz/Weiß je nach Helligkeit der Füllfarbe (Lesbarkeit).
    private static func contrastColor(_ fill: NSColor) -> NSColor {
        let c = fill.usingColorSpace(.sRGB) ?? fill
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum < 0.55 ? .white : ink
    }
}

// MARK: - Farb-Helfer

private extension NSColor {
    /// „RRGGBB" → NSColor (sRGB). Nil bei ungültigem Hex.
    convenience init?(hex: String) {
        guard hex.count == 6,
              let r = Int(hex.prefix(2), radix: 16),
              let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
              let b = Int(hex.suffix(2), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
