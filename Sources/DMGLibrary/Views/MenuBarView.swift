import SwiftUI

/// 菜单栏快速入口。
struct MenuBarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Button(prefs.t("menu.search")) {
            activate()
            NotificationCenter.default.post(name: .libraryFocusSearch, object: nil)
        }

        Divider()

        Button(prefs.t("menu.add")) {
            activate()
            NotificationCenter.default.post(name: .libraryAddFiles, object: nil)
        }

        Button(prefs.t("menu.scan")) {
            activate()
            NotificationCenter.default.post(name: .libraryScanFolder, object: nil)
        }

        Divider()

        Menu(prefs.t("menu.favorites", store.count(for: .favorites))) {
            ForEach(favorites.prefix(10)) { item in
                Button {
                    activate()
                    NotificationCenter.default.post(name: .librarySelectItem, object: item.id)
                } label: {
                    Text(item.effectiveDisplayName)
                }
            }
            if favorites.isEmpty {
                Text(prefs.t("menu.noFavorites"))
            }
        }

        Menu(prefs.t("menu.recent", store.count(for: .recent))) {
            ForEach(recent.prefix(10)) { item in
                Button {
                    activate()
                    NotificationCenter.default.post(name: .librarySelectItem, object: item.id)
                } label: {
                    Text(item.effectiveDisplayName)
                }
            }
            if recent.isEmpty {
                Text(prefs.t("menu.noRecent"))
            }
        }

        Divider()

        Button(prefs.t("menu.openWindow")) {
            activate()
        }

        SettingsLink {
            Text(prefs.t("menu.settings"))
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
