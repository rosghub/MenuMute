import SwiftUI
import AppKit
import CoreAudio

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
    private let fallbackRestoreInputVolume = 75
    private var lastNonZeroInputVolumeByDevice: [AudioDeviceID: Int] = [:]

    private var currentInputDeviceID: AudioDeviceID?
    private var observedInputVolumeDeviceID: AudioDeviceID?
    private var observedInputVolumeAddresses: [AudioObjectPropertyAddress] = []
    private var isDefaultInputDeviceObserverRegistered = false

    private static let audioPropertyListenerProc: AudioObjectPropertyListenerProc = {
        objectID,
        numberAddresses,
        addresses,
        clientData in
        guard let clientData else {
            return noErr
        }

        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(clientData).takeUnretainedValue()
        appDelegate.handleAudioPropertyChange(
            objectID: objectID,
            numberAddresses: numberAddresses,
            addresses: addresses
        )
        return noErr
    }

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

        let soundSettingsItem = NSMenuItem(
            title: "System sound settings",
            action: #selector(openSystemSoundSettings),
            keyEquivalent: ""
        )
        soundSettingsItem.target = self
        statusMenu.addItem(soundSettingsItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        setupAudioObservers()
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardownAudioObservers()
    }

    deinit {
        teardownAudioObservers()
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

    @objc private func openSystemSoundSettings() {
        if #available(macOS 13.0, *) {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(settingsURL)
                return
            }
        }

        let legacyPaneURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane")
        NSWorkspace.shared.open(legacyPaneURL)
    }

    private func toggleMute() {
        let currentInput = getInputVolume()
        let currentDeviceID = currentDefaultInputDeviceID()

        if let currentDeviceID {
            self.currentInputDeviceID = currentDeviceID
        }

        if currentInput > 0 {
            if let currentDeviceID {
                lastNonZeroInputVolumeByDevice[currentDeviceID] = currentInput
            }
            setInputVolume(0)
        } else {
            let rememberedVolume = currentDeviceID.flatMap { lastNonZeroInputVolumeByDevice[$0] } ?? fallbackRestoreInputVolume
            let restoreVolume = max(rememberedVolume, 1)
            setInputVolume(restoreVolume)
        }

        refreshState()
    }

    private func refreshState() {
        let currentInput = getInputVolume()
        let currentDeviceID = currentDefaultInputDeviceID()

        if let currentDeviceID {
            self.currentInputDeviceID = currentDeviceID
        }

        if currentInput > 0, let currentDeviceID {
            lastNonZeroInputVolumeByDevice[currentDeviceID] = currentInput
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

    private func setupAudioObservers() {
        registerDefaultInputDeviceObserver()
        handleDefaultInputDeviceChange()
    }

    private func teardownAudioObservers() {
        unregisterInputVolumeObservers()
        unregisterDefaultInputDeviceObserver()
    }

    private func handleDefaultInputDeviceChange() {
        currentInputDeviceID = currentDefaultInputDeviceID()
        rebindInputVolumeObservers(to: currentInputDeviceID)
        refreshState()
    }

    private func handleAudioPropertyChange(
        objectID: AudioObjectID,
        numberAddresses: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) {
        let changedAddresses = UnsafeBufferPointer(start: addresses, count: Int(numberAddresses))

        let defaultInputChanged = objectID == kAudioObjectSystemObject && changedAddresses.contains {
            $0.mSelector == kAudioHardwarePropertyDefaultInputDevice
        }

        if defaultInputChanged {
            DispatchQueue.main.async { [weak self] in
                self?.handleDefaultInputDeviceChange()
            }
            return
        }

        guard objectID == observedInputVolumeDeviceID else {
            return
        }

        let inputVolumeChanged = changedAddresses.contains { $0.mSelector == kAudioDevicePropertyVolumeScalar }
        if inputVolumeChanged {
            DispatchQueue.main.async { [weak self] in
                self?.refreshState()
            }
        }
    }

    private func registerDefaultInputDeviceObserver() {
        guard !isDefaultInputDeviceObserverRegistered else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.audioPropertyListenerProc,
            listenerClientData
        )

        if status == noErr {
            isDefaultInputDeviceObserverRegistered = true
        } else {
            print("Failed to register default input device observer: \(status)")
        }
    }

    private func unregisterDefaultInputDeviceObserver() {
        guard isDefaultInputDeviceObserverRegistered else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.audioPropertyListenerProc,
            listenerClientData
        )

        if status != noErr {
            print("Failed to remove default input device observer: \(status)")
        }

        isDefaultInputDeviceObserverRegistered = false
    }

    private func rebindInputVolumeObservers(to deviceID: AudioDeviceID?) {
        unregisterInputVolumeObservers()

        guard let deviceID else {
            return
        }

        observedInputVolumeDeviceID = deviceID

        for address in makeInputVolumeObserverAddresses() {
            var mutableAddress = address
            let status = AudioObjectAddPropertyListener(
                deviceID,
                &mutableAddress,
                Self.audioPropertyListenerProc,
                listenerClientData
            )

            if status == noErr {
                observedInputVolumeAddresses.append(address)
            } else {
                print(
                    "Failed to register input volume observer for selector \(address.mSelector), element \(address.mElement): \(status)"
                )
            }
        }
    }

    private func unregisterInputVolumeObservers() {
        guard let observedInputVolumeDeviceID else {
            observedInputVolumeAddresses.removeAll()
            return
        }

        for address in observedInputVolumeAddresses {
            var mutableAddress = address
            let status = AudioObjectRemovePropertyListener(
                observedInputVolumeDeviceID,
                &mutableAddress,
                Self.audioPropertyListenerProc,
                listenerClientData
            )

            if status != noErr {
                print(
                    "Failed to remove input volume observer for selector \(address.mSelector), element \(address.mElement): \(status)"
                )
            }
        }

        observedInputVolumeAddresses.removeAll()
        self.observedInputVolumeDeviceID = nil
    }

    private func makeInputVolumeObserverAddresses() -> [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            ),
        ]
    }

    private var listenerClientData: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
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
