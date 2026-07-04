//
//  Brotherhood.swift
//  Logbuch Loader
//
//  Die sieben deutschen Seelotsen-Lotsenbrüderschaften (Reviere). Die
//  offiziellen Logos der Bundeslotsenkammer werden bewusst NICHT mit der App
//  ausgeliefert, sondern beim Erstellen des Ausbildungsbuchs direkt von der
//  BLK-Website geladen (siehe `logoURL`).
//

import Foundation

struct Brotherhood: Identifiable, Hashable {
    /// Stabiler Schlüssel für die Persistenz der Auswahl.
    let id: String
    /// Anzeigename in der Auswahlliste.
    let name: String
    /// Offizielles Logo auf der Website der Bundeslotsenkammer (PNG oder SVG).
    let logoURL: URL

    /// Alle sieben Reviere, alphabetisch nach Name sortiert.
    static let all: [Brotherhood] = [
        Brotherhood(id: "elbe",
                    name: "Lotsenbrüderschaft Elbe",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2020/02/lotsenbruederschaft-elbe-logo.png")!),
        Brotherhood(id: "emden",
                    name: "Lotsenbrüderschaft Emden",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2020/02/0C3E3584-D39B-419B-93DC-042EB48CD754.png")!),
        Brotherhood(id: "nok1",
                    name: "Lotsenbrüderschaft Nord-Ostsee-Kanal I",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2024/06/Logo_pilot-nok-1_neu.svg")!),
        Brotherhood(id: "nok2",
                    name: "Lotsenbrüderschaft Nord-Ostsee-Kanal II / Kiel / Lübeck / Flensburg",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2020/02/lotsenbruederschaft-nord-ostsee-kanal-2-logo.png")!),
        Brotherhood(id: "weser1",
                    name: "Lotsenbrüderschaft Weser I",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2021/07/lotsenbruederschaft-weser-1-logo.png")!),
        Brotherhood(id: "weser2jade",
                    name: "Lotsenbrüderschaft Weser II / Jade",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2020/02/hafenlotsenbruederschaft-weser2-jade-logo.png")!),
        Brotherhood(id: "wrs",
                    name: "Lotsenbrüderschaft Wismar / Rostock / Stralsund",
                    logoURL: URL(string: "https://www.bundeslotsenkammer.de/wp-content/uploads/2020/02/lotsenbruederschaft-wismar-rostock-stralsund-logo.png")!),
    ]

    /// Findet ein Revier anhand seines `id`-Schlüssels.
    static func named(_ id: String) -> Brotherhood? { all.first { $0.id == id } }
}
