import Foundation
import Network

struct VpnNode: Identifiable, Hashable {
    let id: String
    let hostName: String
    let ip: String
    let score: Int
    let reportedPingMs: Int
    let speedBps: Double
    let countryLong: String
    let countryShort: String
    let sessions: Int
    let uptimeSec: Int
    let ovpnConfig: String
    let remoteHost: String
    let remotePort: UInt16
    let proto: String
    var liveLatencyMs: Int?
    var probeFailed: Bool = false

    var speedMbps: Double { speedBps / 1_000_000.0 }

    var effectiveLatencyMs: Int {
        if let live = liveLatencyMs { return live }
        return reportedPingMs > 0 ? reportedPingMs : 9999
    }

    var flagEmoji: String {
        let base: UInt32 = 127397
        var s = ""
        for v in countryShort.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s.isEmpty ? "🌐" : s
    }
}

enum VpnGateError: LocalizedError {
    case badResponse
    case emptyList

    var errorDescription: String? {
        switch self {
        case .badResponse: return "VPNGate returned an invalid response."
        case .emptyList: return "No OpenVPN nodes were returned."
        }
    }
}

final class VpnGateService {
    private let endpoint = URL(string: "https://www.vpngate.net/api/iphone/")!

    func fetchNodes() async throws -> [VpnNode] {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("GateHop/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw VpnGateError.badResponse
        }

        var nodes: [VpnNode] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("*") || trimmed.hasPrefix("#") { continue }
            let cols = trimmed.components(separatedBy: ",")
            guard cols.count >= 15 else { continue }

            let hostName = cols[0]
            let ip = cols[1]
            let score = Int(cols[2]) ?? 0
            let ping = Int(cols[3]) ?? 999
            let speed = Double(cols[4]) ?? 0
            let countryLong = cols[5]
            let countryShort = cols[6]
            let sessions = Int(cols[7]) ?? 0
            let uptime = Int(cols[8]) ?? 0
            let b64 = cols[14]

            guard let cfgData = Data(base64Encoded: b64),
                  let cfg = String(data: cfgData, encoding: .utf8),
                  !cfg.isEmpty else { continue }

            let parsed = parseRemote(from: cfg, fallbackIP: ip)
            let node = VpnNode(
                id: "\(ip):\(parsed.port):\(parsed.proto)",
                hostName: hostName,
                ip: ip,
                score: score,
                reportedPingMs: ping,
                speedBps: speed,
                countryLong: countryLong,
                countryShort: countryShort,
                sessions: sessions,
                uptimeSec: uptime,
                ovpnConfig: cfg,
                remoteHost: parsed.host,
                remotePort: parsed.port,
                proto: parsed.proto,
                liveLatencyMs: nil,
                probeFailed: false
            )
            nodes.append(node)
        }

        if nodes.isEmpty { throw VpnGateError.emptyList }
        return nodes.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.speedBps > $1.speedBps
        }
    }

    private func parseRemote(from ovpn: String, fallbackIP: String) -> (host: String, port: UInt16, proto: String) {
        var host = fallbackIP
        var port: UInt16 = 1194
        var proto = "tcp"
        for rawLine in ovpn.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("remote ") {
                let parts = line.split(separator: " ").map(String.init)
                if parts.count >= 2 { host = parts[1] }
                if parts.count >= 3, let p = UInt16(parts[2]) { port = p }
            } else if line.hasPrefix("proto ") {
                let parts = line.split(separator: " ").map(String.init)
                if parts.count >= 2 { proto = parts[1].lowercased() }
            }
        }
        return (host, port, proto)
    }

    func probeTCP(host: String, port: UInt16, timeoutSec: Double = 2.0) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds

        return await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "dev.nova.gatehop.probe.\(host)")
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false
            let lock = NSLock()

            func finish(_ value: Int?) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: value)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                    let ms = max(1, Int(elapsedNs / 1_000_000))
                    finish(ms)
                case .failed(_), .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSec) {
                finish(nil)
            }
        }
    }

    func exportOvpn(node: VpnNode) throws -> URL {
        let safeCountry = node.countryShort.isEmpty ? "VPN" : node.countryShort.uppercased()
        let filename = "\(safeCountry)_\(node.ip)_\(node.remotePort).ovpn"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try node.ovpnConfig.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
