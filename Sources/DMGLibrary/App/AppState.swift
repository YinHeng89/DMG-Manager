import SwiftUI

/// 应用级共享状态。
///
/// Store 必须在 AppDelegate 里就能拿到：通过 Finder「打开方式」冷启动时，
/// SwiftUI 的窗口不一定会立刻渲染（甚至不渲染），
/// 如果 store 只挂在视图上，这类导入就会丢。
@MainActor
enum AppState {
    static var store: LibraryStore?

    /// 后台轮询 / 安装状态刷新等只应随 App 生命周期启动一次。
    /// WindowGroup 每开一个窗口都会渲染一份 ContentView，若把任务挂在视图 `.task` 上，
    /// 会随窗口数量线性叠加（N 个窗口 = N 组 2 秒轮询），既浪费又无意义——store 是单例，任务全挂在它上面。
    private(set) static var backgroundTasksStarted = false

    static func bootstrapIfNeeded() {
        guard store == nil else { return }
        store = LibraryStore.bootstrap()
        startBackgroundTasks()
    }

    /// 在 App 级（而非每个窗口）统一启动后台任务，杜绝多窗口重复。
    static func startBackgroundTasks() {
        guard let store, !backgroundTasksStarted else { return }
        backgroundTasksStarted = true

        // 首屏就绪后的初始化：文件状态 / 安装状态 / 监控目录扫描，不阻塞启动。
        Task.detached(priority: .utility) {
            await store.refreshFileStatus()
            await store.refreshInstallStatus()
            await store.scanWatchDirectoriesOnLaunch()
        }

        // 运行期外部文件增删的感知轮询：周期采样存在性，让「文件失联」标签实时跟磁盘同步。
        // 挂在 App 生命周期内，单例只此一份，不随窗口开关而增删。
        Task.detached(priority: .utility) {
            while true {
                await store.refreshPresence()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
