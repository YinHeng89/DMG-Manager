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
                    // 每个列表的计数只算一次：原来 if 和 Text 各调一次 count(for:)（每次全量 filter），
                    // 条目多时重复扫描。先取出来复用。
                    let count = store.count(for: list)
                    Label {
                        HStack {
                            Text(list.title)
                            Spacer()
                            if count > 0 {
                                Text("\(count)")
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
                    let count = store.count(forCategory: category)
                    Label {
                        HStack {
                            Text(category)
                            Spacer()
                            if count > 0 {
                                Text("\(count)")
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
