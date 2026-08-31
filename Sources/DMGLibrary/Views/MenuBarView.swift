import SwiftUI

/// 菜单栏快速入口。
struct MenuBarView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button("搜索 DMG") {
            activate()
            NotificationCenter.default.post(name: .libraryFocusSearch, object: nil)
        }

        Divider()

        Button("添加 DMG…") {
            activate()
            NotificationCenter.default.post(name: .libraryAddFiles, object: nil)
        }

        Button("扫描文件夹…") {
            activate()
            NotificationCenter.default.post(name: .libraryScanFolder, object: nil)
        }

        Divider()

        Menu("收藏 · \(store.count(for: .favorites))") {
            ForEach(favorites.prefix(10)) { item in
                Button {
                    activate()
                    NotificationCenter.default.post(name: .librarySelectItem, object: item.id)
                } label: {
                    Text(item.effectiveDisplayName)
                }
            }
            if favorites.isEmpty {
                Text("还没有收藏")
            }
        }

        Menu("最近添加 · \(store.count(for: .recent))") {
            ForEach(recent.prefix(10)) { item in
                Button {
                    activate()
                    NotificationCenter.default.post(name: .librarySelectItem, object: item.id)
                } label: {
                    Text(item.effectiveDisplayName)
                }
            }
            if recent.isEmpty {
                Text("最近没有新增")
            }
        }

        Divider()

        Button("打开主窗口") {
            activate()
        }

        SettingsLink {
            Text("设置…")
        }
    }

    private var favorites: [DMGItem] {
        store.items.filter(\.favorite).sorted { $0.effectiveDisplayName < $1.effectiveDisplayName }
    }

    private var recent: [DMGItem] {
        store.items.sorted { $0.createdAt > $1.createdAt }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let librarySelectItem = Notification.Name("DMGLibrary.SelectItem")
}
