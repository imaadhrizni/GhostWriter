import Foundation

// MARK: - Catalog → Graph adapter
//
// Feeds the live Catalog into `CatalogGraph` as plain input, so the graph logic
// stays free of the store's storage types (and unit-testable on its own).

extension CatalogStore {
    func graphInput() -> CatalogGraph.Input {
        CatalogGraph.Input(
            orgs: doc.orgs.map {
                .init(id: $0.id, name: $0.name, parentID: $0.parentID,
                      relationship: $0.relationship.label, isInternal: $0.isInternal)
            },
            projects: doc.projects.map {
                .init(id: $0.id, name: $0.archived ? "\($0.name) (archived)" : $0.name,
                      orgID: $0.orgID, parentID: $0.parentID,
                      stage: $0.stage.rawValue, valueCents: $0.valueCents)
            },
            people: doc.people.map { .init(id: $0.id, name: $0.name, designation: $0.designation ?? "") },
            tags: doc.tags.map { .init(id: $0.id, name: $0.name) },
            notes: doc.notes.map {
                .init(id: $0.id, title: $0.title, date: $0.date, projectIDs: $0.projectIDs,
                      orgIDs: $0.orgIDs, tagIDs: $0.tagIDs, personIDs: $0.personIDs)
            })
    }
}
