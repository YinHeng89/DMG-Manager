import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        List(selection: Binding(
            get: { store.selection },
            set: { store.selection = $0 }
        )) {
            Section(prefs.t("sidebar.library")) {
                ForEach([SmartList.all, .favorites, .recent, .recentlyUsed, .missing, .duplicates]) { list in
                    Label {
                        HStack {
                            Text(list.title)
                            Spacer()
                            if store.count(for: list) > 0 {
                                Text("\(store.count(for: list))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: list.symbolName)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarSelection.smart(list))
                }
            }

            Section {
                ForEach(visibleCategories, id: \.self) { category in
                    Label {
                        HStack {
                            Text(category)
                            Spacer()
                            if store.count(forCategory: category) > 0 {
                                Text("\(store.count(forCategory: category))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarSelection.category(category))
                }
            } header: {
                Text(prefs.t("sidebar.categories"))
            }

            if !store.tagCounts.isEmpty {
                Section(prefs.t("sidebar.tags")) {
                    ForEach(store.tagCounts, id: \.name) { entry in
                        Label {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                Text("\(store.count(forTag: entry.name))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "tag")
                                .foregroundStyle(.secondary)
                        }
                        .tag(SidebarSelection.tag(entry.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 只显示有内容的分类，加上「未分类」，避免侧边栏过长。
    private var visibleCategories: [String] {
        let used = Set(items(using: \.category))
        let ordered = CategoryPresets.builtin.filter { used.contains($0) }
        return ordered + store.customCategories.filter { used.contains($0) && !ordered.contains($0) }
    }

    private func items(using keyPath: KeyPath<DMGItem, String>) -> [String] {
        store.items.map { $0[keyPath: keyPath] }
    }
}
