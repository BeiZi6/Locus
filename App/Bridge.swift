import CoreLocation
import Foundation

@MainActor
final class DeviceBridge: ObservableObject {
    @Published var devices: [DeviceItem] = []
    @Published var warnings: [String] = []
    @Published var status = "正在启动本机服务"
    @Published var lastError: String?
    @Published var busy = false
    @Published var simulating = false

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]
    private var ready = false

    func start() {
        guard process == nil else { return }
        let root = Self.projectRoot()
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            status = "找不到 Python 环境"
            lastError = python.path
            return
        }
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = python
        process.arguments = ["-m", "locus.worker"]
        var env = ProcessInfo.processInfo.environment
        env["NO_PROXY"] = "*"
        env["no_proxy"] = "*"
        env["PYTHONPATH"] = root.appendingPathComponent("src").path
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = "本机服务已退出"
                self.ready = false
                let pending = self.waiters
                self.waiters.removeAll()
                pending.values.forEach { $0.resume(throwing: BridgeError.offline) }
            }
        }
        do {
            try process.run()
        } catch {
            status = "本机服务没有启动"
            lastError = error.localizedDescription
            return
        }
        self.process = process
        stdin = input.fileHandleForWriting
        status = "正在读取设备"
        Task { await refresh() }
    }

    func refresh() async {
        do {
            let payload = try await request(["op": "list"])
            devices = Self.decodeDevices(payload["devices"])
            warnings = payload["warnings"] as? [String] ?? []
            status = devices.isEmpty ? "没有连接的设备" : "已看到 \(devices.count) 台设备"
            lastError = nil
            ready = true
        } catch {
            lastError = error.localizedDescription
            status = "读取设备失败"
        }
    }

    func apply(
        target: String,
        coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        speed: Double,
        bearing: Double,
        altitude: Double = 32,
        quiet: Bool = false
    ) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let payload = try await request([
                "op": "set",
                "target": target,
                "lat": coordinate.latitude,
                "lon": coordinate.longitude,
                "accuracy": accuracy,
                "speed": speed,
                "bearing": bearing,
                "altitude": altitude,
            ])
            simulating = true
            if !quiet {
                let providers = (payload["providers"] as? [String]) ?? []
                let via = providers.map { $0 == "developer" ? "开发者通道" : $0 }.joined(separator: "+")
                status = String(
                    format: "±%.0f m · %.1f km/h · %.0f° · %@",
                    accuracy,
                    speed * 3.6,
                    bearing,
                    via
                )
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            status = "写入失败"
            return false
        }
    }

    func clear(target: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await request(["op": "clear", "target": target])
            simulating = false
            status = "已停止模拟"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = "停止失败"
        }
    }

    func stop() {
        stdin?.closeFile()
        process?.terminate()
        process = nil
    }

    private func request(_ body: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var message = body
        message["id"] = id
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let stdin else { throw BridgeError.offline }
        var line = data
        line.append(0x0A)
        try stdin.write(contentsOf: line)
        let reply = try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
        }
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        return object ?? [:]
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any] else { continue }
            let id = object["id"] as? Int
            let waiter = id.flatMap { waiters.removeValue(forKey: $0) }
            if object["ok"] as? Bool == true {
                waiter?.resume(returning: chunk)
            } else {
                let message = object["error"] as? String ?? "设备没有接受这次操作"
                waiter?.resume(throwing: BridgeError.message(message))
            }
        }
    }

    private static func decodeDevices(_ raw: Any?) -> [DeviceItem] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let kind = row["kind"] as? String,
                  let name = row["name"] as? String,
                  let detail = row["detail"] as? String else { return nil }
            return DeviceItem(id: id, kind: kind, name: name, detail: detail)
        }
    }

    private static func projectRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["LOCUS_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        var url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let python = url.appendingPathComponent(".venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: python.path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/Users/xyu/Projects/Locus")
    }
}

enum BridgeError: LocalizedError {
    case offline
    case message(String)

    var errorDescription: String? {
        switch self {
        case .offline: "本机服务还没有就绪"
        case .message(let text): text
        }
    }
}
