import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let appGroupId = "group.app.tachyon.proxy"

    private let engineQueue = DispatchQueue(label: "app.tachyon.proxy.tunnel.engine", qos: .userInitiated)
    private var utunInterfaceName: String = ""
    private var baselineUpBytes: UInt64 = 0
    private var baselineDownBytes: UInt64 = 0
    private var lastErrorMessage: String = ""

    private var workingDirectory: URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            try? FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
            return groupURL
        }
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tachyon", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private var logFileURL: URL {
        workingDirectory.appendingPathComponent("core.log")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let protoConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let rawConfig = (options?["config"] as? String)
            ?? (protoConfig?["config"] as? String)
            ?? (try? String(contentsOf: workingDirectory.appendingPathComponent("active_config.json"), encoding: .utf8))
            ?? ""

        guard !rawConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let err = makeError("Пустая конфигурация туннеля")
            lastErrorMessage = err.localizedDescription
            completionHandler(err)
            return
        }

        let mtu = (options?["mtu"] as? NSNumber)?.intValue
            ?? (protoConfig?["mtu"] as? NSNumber)?.intValue
            ?? 9000
        let proxyOnly = (options?["proxyOnly"] as? NSNumber)?.boolValue
            ?? (protoConfig?["proxyOnly"] as? NSNumber)?.boolValue
            ?? false

        // Сохраняем переданные бинарные списки .trs (если App Group недоступна при sideload-подписи)
        if let trsFiles = protoConfig?["trsFiles"] as? [String: Data], !trsFiles.isEmpty {
            let listsDir = workingDirectory.appendingPathComponent("lists", isDirectory: true)
            try? FileManager.default.createDirectory(at: listsDir, withIntermediateDirectories: true)
            for (name, data) in trsFiles {
                let dst = listsDir.appendingPathComponent(name)
                try? data.write(to: dst, options: .atomic)
            }
        }

        let settings = buildNetworkSettings(from: rawConfig, defaultMtu: mtu)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastErrorMessage = "Не удалось применить сетевые настройки iOS: \(error.localizedDescription)"
                completionHandler(error)
                return
            }

            self.engineQueue.async {
                let workDir = self.workingDirectory
                FileManager.default.changeCurrentDirectoryPath(workDir.path)

                let preparedConfig = self.prepareConfigJson(rawConfig, logPath: self.logFileURL.path, workDir: workDir)
                let tunFd: Int32
                if proxyOnly {
                    tunFd = -1
                    self.utunInterfaceName = ""
                } else {
                    let resolved = self.resolveTunnelFileDescriptor()
                    tunFd = resolved.fd
                    self.utunInterfaceName = resolved.ifname
                }

                if !proxyOnly && tunFd < 0 {
                    let err = self.makeError("Не найден файловый дескриптор utun интерфейса NEPacketTunnelProvider")
                    self.lastErrorMessage = err.localizedDescription
                    completionHandler(err)
                    return
                }

                if !self.utunInterfaceName.isEmpty {
                    let initialCounters = Self.readInterfaceBytes(name: self.utunInterfaceName)
                    self.baselineUpBytes = initialCounters.up
                    self.baselineDownBytes = initialCounters.down
                } else {
                    self.baselineUpBytes = 0
                    self.baselineDownBytes = 0
                }

                let rc = preparedConfig.withCString { cstr in
                    tachyon_core_start(cstr, tunFd)
                }

                if rc != 0 {
                    let detail = Self.consumeCoreLastError() ?? "код ошибки \(rc)"
                    self.lastErrorMessage = detail
                    self.appendLogLine("[ERROR] tachyon_core_start failed: \(detail)")
                    completionHandler(self.makeError(detail))
                    return
                }

                self.lastErrorMessage = ""
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        engineQueue.async {
            _ = tachyon_core_stop()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler else { return }
        guard
            let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            let cmd = obj["cmd"] as? String
        else {
            completionHandler(nil)
            return
        }

        switch cmd {
        case "stats":
            let running = tachyon_core_is_running() == 1
            var up: UInt64 = 0
            var down: UInt64 = 0
            if running, !utunInterfaceName.isEmpty {
                let current = Self.readInterfaceBytes(name: utunInterfaceName)
                up = current.up >= baselineUpBytes ? (current.up - baselineUpBytes) : current.up
                down = current.down >= baselineDownBytes ? (current.down - baselineDownBytes) : current.down
            }
            let reply: [String: Any] = [
                "running": running,
                "up": up,
                "down": down,
                "connections": 0,
            ]
            let data = try? JSONSerialization.data(withJSONObject: reply)
            completionHandler(data)

        case "status":
            let running = tachyon_core_is_running() == 1
            let reply: [String: Any] = [
                "running": running,
                "error": lastErrorMessage,
            ]
            let data = try? JSONSerialization.data(withJSONObject: reply)
            completionHandler(data)

        case "logs":
            let limit = (obj["limit"] as? Int) ?? 400
            let lines = readTailLines(from: logFileURL, limit: limit)
            let reply: [String: Any] = ["lines": lines]
            let data = try? JSONSerialization.data(withJSONObject: reply)
            completionHandler(data)

        case "clearLogs":
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
            let reply: [String: Any] = ["ok": true]
            let data = try? JSONSerialization.data(withJSONObject: reply)
            completionHandler(data)

        case "reload":
            guard let newConfig = obj["config"] as? String, !newConfig.isEmpty else {
                completionHandler(nil)
                return
            }
            engineQueue.async {
                let workDir = self.workingDirectory
                let prepared = self.prepareConfigJson(newConfig, logPath: self.logFileURL.path, workDir: workDir)
                let rc = prepared.withCString { cstr in
                    tachyon_core_reload(cstr)
                }
                let err = rc == 0 ? "" : (Self.consumeCoreLastError() ?? "reload failed")
                let reply: [String: Any] = ["ok": rc == 0, "error": err]
                let data = try? JSONSerialization.data(withJSONObject: reply)
                completionHandler(data)
            }

        default:
            completionHandler(nil)
        }
    }

    // MARK: - Helpers

    private func buildNetworkSettings(from configJson: String, defaultMtu: Int) -> NEPacketTunnelNetworkSettings {
        var tunnelAddress = "172.19.0.1"
        var subnetMask = "255.255.255.252"
        var mtu = defaultMtu

        if let data = configJson.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inbounds = root["inbounds"] as? [[String: Any]] {
            for inbound in inbounds where (inbound["type"] as? String) == "tun" {
                if let m = inbound["mtu"] as? Int, m >= 1280 {
                    mtu = m
                }
                if let addrs = inbound["address"] as? [String], let first = addrs.first {
                    let parts = first.split(separator: "/")
                    if let ip = parts.first {
                        tunnelAddress = String(ip)
                    }
                    if parts.count == 2, let prefix = Int(parts[1]) {
                        subnetMask = Self.ipv4PrefixToMask(prefix)
                    }
                } else if let addrStr = inbound["inet4_address"] as? String {
                    let parts = addrStr.split(separator: "/")
                    if let ip = parts.first {
                        tunnelAddress = String(ip)
                    }
                    if parts.count == 2, let prefix = Int(parts[1]) {
                        subnetMask = Self.ipv4PrefixToMask(prefix)
                    }
                }
                break
            }
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "172.19.0.2")
        // На iOS utun стабильнее всего работает при MTU <= 4064 (ограничение пула mbuf NEPacketTunnelProvider)
        settings.mtu = NSNumber(value: min(max(mtu, 1280), 4064))

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["172.19.0.2", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        return settings
    }

    private func prepareConfigJson(_ rawJson: String, logPath: String, workDir: URL) -> String {
        guard
            let data = rawJson.data(using: .utf8),
            var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return rawJson
        }

        // Записываем путь к файлу лога
        var logSection = (root["log"] as? [String: Any]) ?? ["level": "info", "timestamp": true]
        logSection["output"] = logPath
        root["log"] = logSection

        // Перенаправляем experimental.cache_file в рабочую директорию App Group / Caches расширения
        var experimental = (root["experimental"] as? [String: Any]) ?? [:]
        var cacheFile = (experimental["cache_file"] as? [String: Any]) ?? ["enabled": true]
        cacheFile["enabled"] = true
        cacheFile["path"] = workDir.appendingPathComponent("cache.db").path
        experimental["cache_file"] = cacheFile
        root["experimental"] = experimental

        // Ограничиваем MTU на tun-инбаунде до 4064 для соответствия NEPacketTunnelNetworkSettings
        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                if (inbounds[i]["type"] as? String) == "tun" {
                    let curMtu = (inbounds[i]["mtu"] as? Int) ?? 9000
                    inbounds[i]["mtu"] = min(max(curMtu, 1280), 4064)
                }
            }
            root["inbounds"] = inbounds
        }

        // Проверяем пути к локальным бинарным спискам .trs
        if var route = root["route"] as? [String: Any],
           var ruleSets = route["rule_set"] as? [[String: Any]] {
            let localListsDir = workDir.appendingPathComponent("lists", isDirectory: true)
            for i in ruleSets.indices {
                if (ruleSets[i]["type"] as? String) == "local",
                   let origPath = ruleSets[i]["path"] as? String,
                   !FileManager.default.fileExists(atPath: origPath) {
                    let fileName = URL(fileURLWithPath: origPath).lastPathComponent
                    let fallbackPath = localListsDir.appendingPathComponent(fileName).path
                    if FileManager.default.fileExists(atPath: fallbackPath) {
                        ruleSets[i]["path"] = fallbackPath
                    }
                }
            }
            route["rule_set"] = ruleSets
            root["route"] = route
        }

        guard let outData = try? JSONSerialization.data(withJSONObject: root),
              let outStr = String(data: outData, encoding: .utf8) else {
            return rawJson
        }
        return outStr
    }

    private func resolveTunnelFileDescriptor() -> (fd: Int32, ifname: String) {
        // 1. Попытка получить дескриптор через KVC (iOS 12–15)
        if let kvcFd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, kvcFd >= 0 {
            let name = Self.queryUtunInterfaceName(fd: kvcFd) ?? "utun"
            return (kvcFd, name)
        }

        // 2. Поиск открытого сокета utun (SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2) для iOS 16 / 17 / 18+
        for fd: Int32 in 0...1024 {
            if let name = Self.queryUtunInterfaceName(fd: fd), name.hasPrefix("utun") {
                return (fd, name)
            }
        }
        return (-1, "")
    }

    private static func queryUtunInterfaceName(fd: Int32) -> String? {
        var ifname = [CChar](repeating: 0, count: 64)
        var len = socklen_t(ifname.count)
        // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2
        let ret = getsockopt(fd, 2, 2, &ifname, &len)
        guard ret == 0, len > 0 else {
            return nil
        }
        let name = String(cString: ifname)
        return name.hasPrefix("utun") ? name : nil
    }

    private static func readInterfaceBytes(name: String) -> (up: UInt64, down: UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let ifa = addr.pointee
            if let cName = ifa.ifa_name,
               String(cString: cName) == name,
               let ifaAddr = ifa.ifa_addr,
               ifaAddr.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = ifa.ifa_data {
                let netData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                return (up: UInt64(netData.ifi_obytes), down: UInt64(netData.ifi_ibytes))
            }
            cursor = ifa.ifa_next
        }
        return (0, 0)
    }

    private static func consumeCoreLastError() -> String? {
        guard let ptr = tachyon_core_last_error() else { return nil }
        defer { tachyon_core_string_free(ptr) }
        let msg = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? nil : msg
    }

    private func readTailLines(from fileURL: URL, limit: Int) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let allLines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if allLines.count <= limit {
            return allLines
        }
        return Array(allLines.suffix(limit))
    }

    private func appendLogLine(_ line: String) {
        let formatted = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = formatted.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path),
               let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    private static func ipv4PrefixToMask(_ prefix: Int) -> String {
        let clamped = max(0, min(32, prefix))
        let mask: UInt32 = clamped == 0 ? 0 : ~((1 << (32 - clamped)) - 1)
        let a = (mask >> 24) & 0xFF
        let b = (mask >> 16) & 0xFF
        let c = (mask >> 8) & 0xFF
        let d = mask & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "app.tachyon.proxy.tunnel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
