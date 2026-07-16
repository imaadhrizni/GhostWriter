import SwiftUI
import AppKit

/// A searchable, indented org→project→sub-project **tree** in a popover — the
/// same shape as the dashboard's account picker, extended to projects. Binds a
/// (kind, id) selection: kind is "", "org", or "project". Reused wherever you
/// pick an org/project so every such control shows the real hierarchy instead
/// of a "›"-joined path string.
struct OrgProjectTreePicker: View {
    @ObservedObject var store: CatalogStore
    @Binding var kind: String     // "", "org", "project"
    @Binding var id: String
    /// The top "clear" row's label; `nil` makes a selection mandatory (no row).
    var allLabel: String? = "All"
    var allIcon: String = "tray"
    /// Which entities to offer (both / orgs only / projects only).
    var scope: CatalogStore.TreeScope = .both
    /// Ids (and their subtrees) to hide — e.g. a parent picker excludes itself.
    var excluding: Set<String> = []
    /// Placeholder shown when mandatory and nothing is chosen yet.
    var placeholder: String = "Choose…"
    @State private var open = false
    @State private var query = ""

    private var currentLabel: String {
        if kind == "org", let o = store.org(id) { return o.name }
        if kind == "project", let p = store.project(id) { return p.name }
        return allLabel ?? placeholder
    }

    private var rows: [CatalogStore.TreeRow] {
        store.orgProjectRows(matching: query, scope: scope, excluding: excluding)
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.isEmpty ? allIcon : (kind == "org" ? "building.2" : "folder")).font(.caption)
                Text(currentLabel).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                List {
                    if let allLabel {
                        treeRow(name: allLabel, icon: allIcon, selected: kind.isEmpty, depth: 0, selectable: true) {
                            kind = ""; id = ""; open = false; query = ""
                        }
                    }
                    ForEach(rows) { r in
                        treeRow(name: r.name, icon: r.kind == "org" ? "building.2" : "folder",
                                selected: kind == r.kind && id == r.id, depth: r.depth, selectable: r.selectable) {
                            kind = r.kind; id = r.id; open = false; query = ""
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding(10).frame(width: 280, height: 340)
        }
    }

    @ViewBuilder
    private func treeRow(name: String, icon: String, selected: Bool, depth: Int,
                         selectable: Bool, action: @escaping () -> Void) -> some View {
        if selectable {
            Button(action: action) {
                rowBody(name: name, icon: icon, selected: selected, depth: depth, dimmed: false)
            }
            .buttonStyle(.plain)
        } else {
            // Context-only row (e.g. an org shown in a projects-only picker).
            rowBody(name: name, icon: icon, selected: false, depth: depth, dimmed: true)
        }
    }

    private func rowBody(name: String, icon: String, selected: Bool, depth: Int, dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(name).lineLimit(1).foregroundStyle(dimmed ? .secondary : .primary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
    }
}
