//
//  BrotherhoodTests.swift
//  Logbuch LoaderTests
//

import XCTest
@testable import Logbuch_Loader

final class BrotherhoodTests: XCTestCase {

    func testAllSevenRevierePresent() {
        XCTAssertEqual(Brotherhood.all.count, 7)
    }

    func testRevierareAlphabeticallySorted() {
        let names = Brotherhood.all.map(\.name)
        XCTAssertEqual(names, names.sorted())
    }

    func testNamedLookupFindsRevier() {
        XCTAssertEqual(Brotherhood.named("nok1")?.name,
                       "Lotsenbrüderschaft Nord-Ostsee-Kanal I")
    }

    func testNamedLookupReturnsNilForUnknownID() {
        XCTAssertNil(Brotherhood.named("gibtsnicht"))
    }

    func testAllIDsAreUnique() {
        let ids = Brotherhood.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testLogoURLsUseHTTPS() {
        for revier in Brotherhood.all {
            XCTAssertEqual(revier.logoURL.scheme, "https", "\(revier.id) nutzt kein HTTPS")
        }
    }
}
