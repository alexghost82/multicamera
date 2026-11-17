import AppKit
import SwiftUI
import CameraCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: WallModel?
    private let languageSettings = LanguageSettings()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let configURL: URL
        if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) {
            configURL = URL(fileURLWithPath: args[index + 1])
        } else { configURL = ConfigurationStore.defaultURL }
        let model = WallModel(configURL: configURL, languageSettings: languageSettings)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1536, height: 1024),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = languageSettings.localized("ACTA CameraWall")
        window.contentView = NSHostingView(rootView: WallView(model: model, languageSettings: languageSettings))
        window.minSize = NSSize(width: 1280, height: 800)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        languageSettings.onChange = { [weak self] in self?.updateMainMenu() }
        updateMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        if args.contains("--detect") { model.detectionEnabled = true }
        model.startApplicationServices()
    }
    private func updateMainMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: languageSettings.localized("Quit CameraWall"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: languageSettings.localized("Edit"))
        editMenu.addItem(withTitle: languageSettings.localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: languageSettings.localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: languageSettings.localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: languageSettings.localized("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--check-vlm-language") {
    do {
        FileHandle.standardOutput.write(try VLMResponseLanguage.selfCheck())
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("VLM language self-check failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains(where: {
    ["--worker", "--install-worker-agent", "--bootstrap-worker-agent",
     "--bootout-worker-agent", "--uninstall-worker-agent"].contains($0)
}) {
    MainActor.assumeIsolated {
        WorkerAgent.startFromCommandLine(arguments: CommandLine.arguments)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()