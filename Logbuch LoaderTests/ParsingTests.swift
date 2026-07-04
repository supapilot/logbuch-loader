//
//  ParsingTests.swift
//  Logbuch LoaderTests
//
//  Tests für die fragilen Parsing-/Namensfunktionen, die von der HTML-Struktur
//  bzw. den Datumsformaten des Portals abhängen.
//

import XCTest
@testable import Logbuch_Loader

final class ParsingTests: XCTestCase {

    // MARK: dateRank

    func testDateRankProducesSortableNumber() {
        XCTAssertEqual(LogbuchService.dateRank("28.06.2026"), 20260628)
        XCTAssertEqual(LogbuchService.dateRank("01.07.2026"), 20260701)
    }

    func testDateRankOrdersChronologically() {
        XCTAssertGreaterThan(LogbuchService.dateRank("01.07.2026"),
                             LogbuchService.dateRank("30.06.2026"))
        XCTAssertLessThan(LogbuchService.dateRank("31.12.2025"),
                          LogbuchService.dateRank("01.01.2026"))
    }

    func testDateRankReturnsZeroForInvalidInput() {
        XCTAssertEqual(LogbuchService.dateRank("kein Datum"), 0)
        XCTAssertEqual(LogbuchService.dateRank(""), 0)
    }

    // MARK: sanitizeFileName

    func testSanitizeFileNameReplacesIllegalCharacters() {
        XCTAssertEqual(LogbuchService.sanitizeFileName("MV Test/Ship"), "MV Test_Ship")
        XCTAssertEqual(LogbuchService.sanitizeFileName("A:B"), "A_B")
    }

    func testSanitizeFileNameLeavesCleanNamesUntouched() {
        XCTAssertEqual(LogbuchService.sanitizeFileName("Vertom Anne Marit"), "Vertom Anne Marit")
    }

    // MARK: extractAspirantID

    func testExtractAspirantIDFromCSVLink() {
        let html = "<a href=\"/wp-content/themes/lotsen-pwa/csv_data_structure.php?id='+12345\">CSV</a>"
        XCTAssertEqual(LogbuchService.extractAspirantID(from: html), "12345")
    }

    func testExtractAspirantIDPlainQuery() {
        XCTAssertEqual(LogbuchService.extractAspirantID(from: "csv_data_structure.php?id=678"), "678")
    }

    func testExtractAspirantIDReturnsNilWhenAbsent() {
        XCTAssertNil(LogbuchService.extractAspirantID(from: "<html>ohne Link</html>"))
    }

    // MARK: prepareDownloads

    func testPrepareDownloadsFileNamesAndDescendingOrder() {
        let drives = [
            Drive(uniqueID: "1", driveNumber: 1, shipName: "Eagle II",   onBoardDate: "28.06.2026"),
            Drive(uniqueID: "2", driveNumber: 2, shipName: "Baltic Star", onBoardDate: "01.07.2026"),
        ]
        let result = LogbuchService.prepareDownloads(drives)
        // Neueste zuerst (absteigende driveNumber).
        XCTAssertEqual(result.map(\.drive.driveNumber), [2, 1])
        XCTAssertEqual(result[0].fileName, "2026.07.1 Baltic Star.pdf")
        XCTAssertEqual(result[1].fileName, "2026.06.28 Eagle II.pdf")
    }

    func testPrepareDownloadsAddsSuffixForSameDay() {
        let drives = [
            Drive(uniqueID: "a", driveNumber: 5, shipName: "Ship A", onBoardDate: "10.05.2026"),
            Drive(uniqueID: "b", driveNumber: 6, shipName: "Ship B", onBoardDate: "10.05.2026"),
        ]
        let byID = Dictionary(uniqueKeysWithValues:
            LogbuchService.prepareDownloads(drives).map { ($0.drive.uniqueID, $0.fileName) })
        // Innerhalb des Tages nach driveNumber aufsteigend nummeriert.
        XCTAssertEqual(byID["a"], "2026.05.10 (1) Ship A.pdf")
        XCTAssertEqual(byID["b"], "2026.05.10 (2) Ship B.pdf")
    }

    func testPrepareDownloadsSanitizesShipNames() {
        let drives = [Drive(uniqueID: "x", driveNumber: 1, shipName: "A/B", onBoardDate: "03.02.2026")]
        XCTAssertEqual(LogbuchService.prepareDownloads(drives).first?.fileName, "2026.02.3 A_B.pdf")
    }
}
