import SwiftUI

struct DMGLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(Preferences.shared.t("app.add")) {
                    NotificationCenter.default.post(name: .libraryAddFiles, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(Preferences.shared.t("app.scan")) {
                    NotificationCenter.default.post(name: .libraryScanFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button(Preferences.shared.t("app.quickSearch")) {
                    NotificationCenter.default.post(name: .libraryFocusSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra("DMG Library", systemImage: "opticaldisc") {
            StoreContainer { store in
                MenuBarView()
                    .environment(store)
                    .environment(Preferences.shared)
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            StoreContainer { store in
                SettingsView()
                    .environment(store)
                    .environment(Preferences.shared)
            }
        }
    }
}

extension LibraryStore {
    static func bootstrap() -> LibraryStore? {
        do {
            return try LibraryStore()
        } catch {
            NSLog("数据库初始化失败：\(error)")
            return nil
        }
    }
}

/// 把全局唯一的 store 注入子视图，未就绪时显示占位。
@MainActor
struct StoreContainer<Content: View>: View {
    @ViewBuilder var content: (LibraryStore) -> Content

    var body: some View {
        if let store = AppState.store {
            content(store)
        } else {
            Text(Preferences.shared.t("app.dbNotReady"))
        }
    }
}

/// 根视图：负责启动失败时的兜底展示。
@MainActor
struct RootView: View {
    @State private var store: LibraryStore? = AppState.store

    var body: some View {
        Group {
            if let store {
                ContentView()
                    .environment(store)
                    .environment(Preferences.shared)
                    .preferredColorScheme(Preferences.shared.appearance.colorScheme)
            } else {
                ContentUnavailableView {
                    Label(Preferences.shared.t("app.cannotOpen"), systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(Preferences.shared.t("app.dbWritable"))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            // Store 可能还没由 AppDelegate 创建好（冷启动传文件场景）
            AppState.bootstrapIfNeeded()
            store = AppState.store
        }
    }
}

extension Notification.Name {
    static let libraryAddFiles = Notification.Name("DMGLibrary.AddFiles")
    static let libraryScanFolder = Notification.Name("DMGLibrary.ScanFolder")
    static let libraryFocusSearch = Notification.Name("DMGLibrary.FocusSearch")
    static let libraryShowFilters = Notification.Name("DMGLibrary.ShowFilters")
}
