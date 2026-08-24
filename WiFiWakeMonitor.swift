import AppKit
import CoreWLAN
import Foundation
import IOKit
import SystemConfiguration

private struct Configuration: Decodable {
    let ssids: [String]
    let routers: [String]

    private enum CodingKeys: String, CodingKey {
        case ssids = "SSIDs"
        case routers = "Routers"
    }
}

private let home = FileManager.default.homeDirectoryForCurrentUser
private let installDirectory = home
    .appendingPathComponent("Library/Application Support/WiFiWakeRecovery", isDirectory: true)
private let recoveryScript = installDirectory.appendingPathComponent("wifi-recover.sh").path
private let configPath = installDirectory.appendingPathComponent("config.plist").path
private let logPath = home.appendingPathComponent("Library/Logs/WiFiWakeRecovery.log").path

private func loadConfiguration() -> Configuration {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try PropertyListDecoder().decode(Configuration.self, from: data)
        guard !config.ssids.isEmpty || !config.routers.isEmpty else {
            throw NSError(
                domain: "WiFiWakeRecovery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "At least one SSID or router is required"]
            )
        }
        return config
    } catch {
        fputs("Could not load \(configPath): \(error)\n", stderr)
        exit(1)
    }
}

private let configuration = loadConfiguration()
private let homeSSIDs = Set(configuration.ssids)
private let homeRouters = Set(configuration.routers)

private func appendLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    let url = URL(fileURLWithPath: logPath)

    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: data)
        return
    }

    do {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        fputs("WiFiWakeRecovery log error: \(error)\n", stderr)
    }
}

private func rootDomainBoolean(_ key: String) -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    guard let property = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    ) else {
        return nil
    }

    return (property.takeRetainedValue() as? NSNumber)?.boolValue
}

private func currentSSID() -> String? {
    CWWiFiClient.shared().interface()?.ssid()
}

private func currentIPv4Router() -> String? {
    guard let state = SCDynamicStoreCopyValue(
        nil,
        "State:/Network/Global/IPv4" as CFString
    ) as? [String: Any] else {
        return nil
    }

    return state["Router"] as? String
}

private func targetNetworkState() -> (isTarget: Bool, ssidMatched: Bool, routerMatched: Bool) {
    let ssidMatched = currentSSID().map { homeSSIDs.contains($0) } ?? false
    let routerMatched = currentIPv4Router().map { homeRouters.contains($0) } ?? false
    return (ssidMatched || routerMatched, ssidMatched, routerMatched)
}

final class WakeMonitor: NSObject {
    private var lastHandledWake = Date.distantPast
    private var recoveryRunning = false

    @objc func didWake(_ notification: Notification) {
        let now = Date()
        guard now.timeIntervalSince(lastHandledWake) > 20 else {
            appendLog("Ignored duplicate wake notification")
            return
        }
        lastHandledWake = now

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.handleSettledWake()
        }
    }

    private func handleSettledWake() {
        let lidClosed = rootDomainBoolean("AppleClamshellState") ?? true
        let userTriggered = rootDomainBoolean("IOPMUserTriggeredFullWake") ?? false

        guard !lidClosed && userTriggered else {
            appendLog("Skipped non-user wake (lidClosed=\(lidClosed), userTriggered=\(userTriggered))")
            return
        }

        let network = targetNetworkState()
        guard network.isTarget else {
            appendLog(
                "Skipped non-target wake (ssidMatched=\(network.ssidMatched), " +
                "routerMatched=\(network.routerMatched))"
            )
            return
        }

        guard !recoveryRunning else {
            appendLog("Skipped wake because recovery is already running")
            return
        }
        recoveryRunning = true
        appendLog(
            "Target-network lid-open wake detected; starting Wi-Fi recovery " +
            "(ssidMatched=\(network.ssidMatched), routerMatched=\(network.routerMatched))"
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [recoveryScript, "reset"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                appendLog("Recovery exited \(process.terminationStatus): \(text)")
            } catch {
                appendLog("Could not start recovery script: \(error)")
            }

            DispatchQueue.main.async {
                self?.recoveryRunning = false
            }
        }
    }
}

let monitor = WakeMonitor()
NSWorkspace.shared.notificationCenter.addObserver(
    monitor,
    selector: #selector(WakeMonitor.didWake(_:)),
    name: NSWorkspace.didWakeNotification,
    object: nil
)

let initialNetwork = targetNetworkState()
appendLog(
    "Wake monitor started; target=\(initialNetwork.isTarget), " +
    "ssidMatched=\(initialNetwork.ssidMatched), routerMatched=\(initialNetwork.routerMatched)"
)
RunLoop.main.run()
