import SwiftUI
import AppKit

@main
struct MicMuteMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    private var isMuted = false
    private var lastNonZeroInputVolume = 75

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let toggleItem = NSMenuItem(title: "Toggle Microphone", action: #selector(toggleMuteFromMenu), keyEquivalent: "")
        toggleItem.target = self
        statusMenu.addItem(toggleItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        refreshState()
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            toggleMute()
            return
        }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleMute()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleMuteFromMenu() {
        toggleMute()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleMute() {
        let currentInput = getInputVolume()

        if currentInput > 0 {
            lastNonZeroInputVolume = currentInput
            setInputVolume(0)
        } else {
            let restoreVolume = max(lastNonZeroInputVolume, 1)
            setInputVolume(restoreVolume)
        }

        refreshState()
    }

    private func refreshState() {
        let currentInput = getInputVolume()

        if currentInput > 0 {
            lastNonZeroInputVolume = currentInput
        }

        isMuted = (currentInput == 0)
        updateIcon()
        updateMenuTitle()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let imageName = isMuted ? "mic.slash.fill" : "mic.fill"
        let image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        image?.isTemplate = true

        button.image = image
        button.title = ""
        button.toolTip = isMuted ? "Microphone muted" : "Microphone live"
    }

    private func updateMenuTitle() {
        if let firstItem = statusMenu.items.first {
            firstItem.title = isMuted ? "Unmute Microphone" : "Mute Microphone"
        }
    }

    private func getInputVolume() -> Int {
        let result = runAppleScript(#"input volume of (get volume settings)"#)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Int(result) ?? 0
    }

    private func setInputVolume(_ value: Int) {
        let clamped = max(0, min(value, 100))
        _ = runAppleScript("set volume input volume \(clamped)")
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                print("AppleScript error: \(error)")
            }

            return output
        } catch {
            print("Failed to run osascript: \(error)")
            return ""
        }
    }
}
