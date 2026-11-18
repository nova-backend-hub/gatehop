import SwiftUI
import UIKit

@MainActor
final class GateViewModel: ObservableObject {
    @Published var nodes: [VpnNode] = []
    @Published var selectedCountry: String = "ALL"
    @Published var autoFastest: Bool = true
    @Published var autoRefresh: Bool = true
    @Published var isLoading: Bool = false
    @Published var isProbing: Bool = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var exportURL: URL?

    private let service = VpnGateService()
    private var refreshTimer: Timer?

    init() {
        Task { await refreshAndProbe() }
        startTimer()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.autoRefresh {
                    await self.refreshAndProbe()
                }
            }
        }
    }

    var countries: [(code: String, name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for n in nodes {
            let cur = counts[n.countryShort] ?? (n.countryLong, 0)
            counts[n.countryShort] = (cur.name, cur.count + 1)
        }
        let sorted = counts
            .map { (code: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        return [(code: "ALL", name: "All", count: nodes.count)] + sorted
    }

    var filteredNodes: [VpnNode] {
        let base = selectedCountry == "ALL"
            ? nodes
            : nodes.filter { $0.countryShort == selectedCountry }

        return base.sorted { a, b in
            if a.probeFailed != b.probeFailed { return !a.probeFailed }
            if let la = a.liveLatencyMs, let lb = b.liveLatencyMs {
                if la != lb { return la < lb }
                return a.speedBps > b.speedBps
            }
            if a.liveLatencyMs != nil { return true }
            if b.liveLatencyMs != nil { return false }
            if autoFastest {
                if a.effectiveLatencyMs != b.effectiveLatencyMs {
                    return a.effectiveLatencyMs < b.effectiveLatencyMs
                }
            }
            return a.speedBps > b.speedBps
        }
    }

    var recommendedNode: VpnNode? {
        filteredNodes.first
    }

    func refreshAndProbe() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await service.fetchNodes()
            nodes = fetched
            lastUpdated = Date()
            isLoading = false
            await probeTopCandidates()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func probeTopCandidates() async {
        guard !isProbing else { return }
        let candidates = filteredNodes
            .filter { $0.proto.contains("tcp") }
            .prefix(12)
        guard !candidates.isEmpty else { return }

        isProbing = true
        await withTaskGroup(of: (String, Int?).self) { group in
            for node in candidates {
                group.addTask {
                    let ms = await self.service.probeTCP(host: node.remoteHost, port: node.remotePort)
                    return (node.id, ms)
                }
            }
            for await (id, ms) in group {
                if let idx = nodes.firstIndex(where: { $0.id == id }) {
                    nodes[idx].liveLatencyMs = ms
                    nodes[idx].probeFailed = (ms == nil)
                }
            }
        }
        isProbing = false
    }

    func sendToOpenVPN(_ node: VpnNode) {
        do {
            exportURL = try service.exportOvpn(node: node)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var vm = GateViewModel()

    private let bg = Color(red: 0.035, green: 0.043, blue: 0.055)
    private let card = Color(red: 0.071, green: 0.086, blue: 0.114)
    private let border = Color.white.opacity(0.08)
    private let accent = Color(red: 0.0, green: 0.898, blue: 0.600)
    private let muted = Color(red: 0.494, green: 0.541, blue: 0.604)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 0) {
                headerBar
                countryStrip
                ScrollView {
                    VStack(spacing: 14) {
                        if let err = vm.errorMessage {
                            errorBanner(err)
                        }
                        if let best = vm.recommendedNode {
                            heroCard(best)
                        } else if vm.isLoading {
                            loadingCard
                        }
                        serverListHeader
                        LazyVStack(spacing: 8) {
                            ForEach(vm.filteredNodes.prefix(40)) { node in
                                serverRow(node)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(item: Binding(
            get: { vm.exportURL.map { ExportItem(url: $0) } },
            set: { if $0 == nil { vm.exportURL = nil } }
        )) { item in
            ShareSheet(url: item.url)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GATEHOP")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text(statusLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(muted)
            }
            Spacer()
            Button {
                vm.autoRefresh.toggle()
            } label: {
                Text(vm.autoRefresh ? "AUTO 5M" : "MANUAL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(vm.autoRefresh ? accent : muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(card)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
                    .cornerRadius(6)
            }
            Button {
                Task { await vm.refreshAndProbe() }
            } label: {
                Image(systemName: vm.isLoading || vm.isProbing ? "antenna.radiowaves.left.and.right" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 34, height: 30)
                    .background(accent)
                    .cornerRadius(6)
            }
            .disabled(vm.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var statusLine: String {
        if vm.isLoading { return "FETCHING VPNGATE FEED..." }
        if vm.isProbing { return "PROBING LIVE RTT..." }
        if let d = vm.lastUpdated {
            let f = DateFormatter()
            f.timeStyle = .short
            return "\(vm.nodes.count) NODES • UPDATED \(f.string(from: d))"
        }
        return "OPENVPN COMPANION"
    }

    private var countryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.countries, id: \.code) { item in
                    let active = vm.selectedCountry == item.code
                    Button {
                        vm.selectedCountry = item.code
                        Task { await vm.probeTopCandidates() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(item.code)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("\(item.count)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .opacity(0.75)
                        }
                        .foregroundColor(active ? .black : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(active ? accent : card)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? accent : border, lineWidth: 1))
                        .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func heroCard(_ node: VpnNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(vm.selectedCountry == "ALL" ? "FASTEST NODE" : "FASTEST IN \(vm.selectedCountry)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                    .tracking(1.2)
                Spacer()
                Text(node.proto.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(node.flagEmoji)
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.countryLong)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(node.ip):\(node.remotePort)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(muted)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                metricBox(
                    label: node.liveLatencyMs != nil ? "LIVE RTT" : "PING",
                    value: "\(node.effectiveLatencyMs) ms",
                    highlight: true
                )
                metricBox(
                    label: "THROUGHPUT",
                    value: String(format: "%.1f Mbps", node.speedMbps),
                    highlight: false
                )
                metricBox(
                    label: "SESSIONS",
                    value: "\(node.sessions)",
                    highlight: false
                )
            }

            Button {
                vm.sendToOpenVPN(node)
            } label: {
                HStack {
                    Image(systemName: "arrow.up.right.square.fill")
                    Text("OPEN IN OPENVPN")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(accent)
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.45), lineWidth: 1))
        .cornerRadius(12)
    }

    private func metricBox(label: String, value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(muted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(highlight ? accent : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverListHeader: some View {
        HStack {
            Text("AVAILABLE NODES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(muted)
            Spacer()
            Button {
                Task { await vm.probeTopCandidates() }
            } label: {
                Text(vm.isProbing ? "PROBING..." : "RE-PROBE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
            }
        }
        .padding(.top, 4)
    }

    private func serverRow(_ node: VpnNode) -> some View {
        Button {
            vm.sendToOpenVPN(node)
        } label: {
            HStack(spacing: 10) {
                Text(node.flagEmoji)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.countryLong)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(node.ip):\(node.remotePort) • \(node.proto.uppercased()) • \(String(format: "%.1f Mbps", node.speedMbps))")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(muted)
                        .lineLimit(1)
                }
                Spacer()
                if node.probeFailed {
                    Text("TIMEOUT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.85))
                } else {
                    Text("\(node.effectiveLatencyMs) ms")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(node.liveLatencyMs != nil ? accent : .white)
                }
            }
            .padding(12)
            .background(card)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
            .cornerRadius(8)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(accent)
            Text("Fetching live OpenVPN servers from VPNGate...")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card)
        .cornerRadius(12)
    }

    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.12))
            .cornerRadius(8)
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
