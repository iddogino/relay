import Foundation

/// Incrementally parses the output of `SSHTmuxScripts.machineLoad`: a
/// stream of `RLOAD_BEGIN` … `RLOAD_END` blocks of `key=value` lines, one
/// block per sample. Malformed or incomplete blocks are dropped — sampling
/// is best-effort.
public struct MachineLoadParser: Sendable {
    static let begin = "RLOAD_BEGIN"
    static let end = "RLOAD_END"

    /// Undecoded bytes: a chunk can end mid-line, even mid-character.
    private var pending = Data()
    private var block: [String]?

    public init() {}

    /// Feeds raw output; returns every sample completed by this chunk.
    /// `now` stamps the samples (receipt time — remote clocks may drift).
    public mutating func feed(_ data: Data, now: Date = Date()) -> [MachineLoadSample] {
        pending.append(data)
        var samples: [MachineLoadSample] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            pending.removeSubrange(pending.startIndex...newline)
            switch line {
            case Self.begin:
                block = []
            case Self.end:
                if let lines = block, let sample = Self.parse(block: lines, date: now) {
                    samples.append(sample)
                }
                block = nil
            default:
                block?.append(line)
                // A block that never ends shouldn't grow without bound.
                if (block?.count ?? 0) > 200 { block = nil }
            }
        }
        if pending.count > 8192 { pending.removeAll() }
        return samples
    }

    /// Parses one block's lines. Requires the core fields (cores, load,
    /// memory); everything else is optional.
    static func parse(block lines: [String], date: Date) -> MachineLoadSample? {
        var single: [String: String] = [:]
        var gpus: [MachineLoadSample.GPU] = []
        var processes: [MachineLoadSample.Process] = []
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "gpu": if let gpu = parseGPU(value) { gpus.append(gpu) }
            case "proc": if let process = parseProcess(value) { processes.append(process) }
            default: if single[key] == nil { single[key] = value }
            }
        }

        guard let cores = single["ncpu"].flatMap(Int.init), cores > 0,
              let load = single["load"].map(numbers), load.count >= 3,
              let mem = single["mem"].map(integers), mem.count == 2, mem[0] > 0
        else { return nil }

        let swap = single["swap"].map(integers)
        let disk = single["disk"].map(integers)
        return MachineLoadSample(
            date: date,
            os: single["os"] ?? "",
            cores: cores,
            load1: load[0], load5: load[1], load15: load[2],
            memoryTotalBytes: mem[0],
            memoryUsedBytes: min(max(mem[1], 0), mem[0]),
            swapTotalBytes: swap?.count == 2 ? swap?[0] : nil,
            swapUsedBytes: swap?.count == 2 ? swap?[1] : nil,
            cpuBusy: single["cpu"].flatMap(Double.init).map { min(max($0 / 1000, 0), 1) },
            diskTotalBytes: disk?.count == 2 ? disk.map { $0[0] * 1024 } : nil,
            diskUsedBytes: disk?.count == 2 ? disk.map { $0[1] * 1024 } : nil,
            uptimeSeconds: single["uptime"].flatMap { Double($0) }.map { Int($0) },
            gpus: gpus,
            processes: processes.sorted { $0.cpuPercent > $1.cpuPercent }
        )
    }

    /// `util memUsedMiB memTotalMiB temp name…` (nvidia-smi, reordered).
    private static func parseGPU(_ value: String) -> MachineLoadSample.GPU? {
        let parts = value.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5,
              let util = Double(parts[0]),
              let used = Int64(parts[1]), let total = Int64(parts[2]), total > 0
        else { return nil }
        return MachineLoadSample.GPU(
            name: String(parts[4]),
            utilization: min(max(util / 100, 0), 1),
            memoryUsedBytes: used << 20,
            memoryTotalBytes: total << 20,
            temperatureC: Int(parts[3])
        )
    }

    /// `pcpu pmem command…`. The command may be a full path containing
    /// spaces (macOS `ps -o comm`); only its last component is kept.
    private static func parseProcess(_ value: String) -> MachineLoadSample.Process? {
        let parts = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let cpu = Double(parts[0]), let mem = Double(parts[1])
        else { return nil }
        let command = String(parts[2])
        var name = command.split(separator: "/").last.map(String.init) ?? command
        // macOS shows exiting/unreadable processes as "(name)".
        if name.count > 2, name.hasPrefix("("), name.hasSuffix(")") { name = String(name.dropFirst().dropLast()) }
        guard !name.isEmpty else { return nil }
        return MachineLoadSample.Process(name: name, cpuPercent: cpu, memoryPercent: mem)
    }

    private static func numbers(_ value: String) -> [Double] {
        value.split(separator: " ").compactMap { Double($0) }
    }

    private static func integers(_ value: String) -> [Int64] {
        value.split(separator: " ").compactMap { Int64($0) }
    }
}
