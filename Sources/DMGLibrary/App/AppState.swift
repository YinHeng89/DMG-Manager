import SwiftUI

/// 应用级共享状态。
///
/// Store 必须在 AppDelegate 里就能拿到：通过 Finder「打开方式」冷启动时，
/// SwiftUI 的窗口不一定会立刻渲染（甚至不渲染），
/// 如果 store 只挂在视图上，这类导入就会丢。
@MainActor
enum AppState {
    static var store: LibraryStore?

    static func bootstrapIfNeeded() {
        guard store == nil else { return }
        store = LibraryStore.bootstrap()
    }
}
