import AppKit

/// 处理 Finder「打开方式」与双击 DMG 传入的文件。
///
/// SwiftUI 的 App 生命周期不一定会把 kAEOpenDocuments 转发给 NSApplicationDelegate，
/// 所以这里直接挂到 NSAppleEventManager 上，冷启动与热启动都能收到。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 应用还没完成启动时收到的文件，等主窗口就绪后再消费。
    static var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        let eventManager = NSAppleEventManager.shared()
        eventManager.setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // 冷启动：事件在 delegate 就绪之前就已经到了
        if let event = eventManager.currentAppleEvent, Self.isOpenDocuments(event) {
            Self.append(Self.urlsFrom(event))
        }
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
        NotificationCenter.default.post(name: .libraryOpenFiles, object: nil)
    }
}

extension Notification.Name {
    static let libraryOpenFiles = Notification.Name("DMGLibrary.OpenFiles")
}
