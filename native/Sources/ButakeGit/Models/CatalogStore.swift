import Foundation
struct CatalogStore {
    let catalog: GitCatalog
    let descriptions: [String: String]
    let glossary: [GlossaryEntry]
    init() {
        func decode<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        catalog = decode("commands", GitCatalog.self) ?? GitCatalog(schemaVersion: 1, gitVersion: "Git", commands: [])
        descriptions = decode("descriptions.es", [String: String].self) ?? [:]
        glossary = decode("glossary.es", [GlossaryEntry].self) ?? []
    }
    func description(_ entry: GitCommandEntry) -> String { descriptions[entry.descriptionKey] ?? entry.name }
}
