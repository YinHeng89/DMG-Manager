import AppKit

/// 处理 Finder「打开方式」与双击 DMG 传入的文件。
///
/// SwiftUI 的 App 生命周期不一定会把 kAEOpenDocuments 转发给 NSApplicationDelegate，
/// 所以这里直接挂到 NSAppleEventManager 上，冷启动与热启动都能收到。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 应用还没完成启动时收到的文件，等主窗口就绪后再消费。
    static var pendingURLs: [URL] = []

    /// 尽早挂上处理器：冷启动时 kAEOpenDocuments 可能在 App 初始化途中就到达，
    /// 晚一步注册就会丢掉这次「打开方式」。
    override init() {
        super.init()
        Self.installOpenDocumentsHandler(self)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installOpenDocumentsHandler(self)
        Self.collectFromCurrentAppleEvent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 让主窗口在「打开方式」冷启动时也能正常出现
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 部分启动路径下事件此时才落到 currentAppleEvent，再兜一次
        Self.collectFromCurrentAppleEvent()
    }

    private static func installOpenDocumentsHandler(_ target: AppDelegate) {
        NSAppleEventManager.shared().setEventHandler(
            target,
            andSelector: #selector(handleOpenDocuments(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    private static func collectFromCurrentAppleEvent() {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              isOpenDocuments(event) else { return }
        append(urlsFrom(event))
    }

    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        Self.append(Self.urlsFrom(event))
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        Self.append([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        Self.append(filenames.map { URL(fileURLWithPath: $0) })
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 内部

    private static func isOpenDocuments(_ event: NSAppleEventDescriptor) -> Bool {
        event.eventClass == AEEventClass(kCoreEventClass) && event.eventID == AEEventID(kAEOpenDocuments)
    }

    private static func urlsFrom(_ event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }

        if direct.descriptorType == typeAEList {
            return (1...direct.numberOfItems).compactMap { index in
                direct.atIndex(index)?.fileURLValue
            }
        }
        return [direct.fileURLValue].compactMap { $0 }
    }


    private static func append(_ urls: [URL]) {
        let dmgFiles = urls.filter { $0.pathExtension.lowercased() == "dmg" }
        guard !dmgFiles.isEmpty else { return }
        pendingURLs.append(contentsOf: dmgFiles)
        Self.drainPendingURLs()
    }

    /// 直接把文件交给 store，不等待窗口渲染。
    static func drainPendingURLs() {
        let urls = pendingURLs
        pendingURLs = []
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            AppState.bootstrapIfNeeded()
            await AppState.store?.importFiles(urls)
        }
    }
}


extension Notification.Name {
    /// 有待导入的 DMG（由「打开方式」/ 双击传入）。
    static let libraryOpenFiles = Notification.Name("DMGLibrary.OpenFiles")
}
