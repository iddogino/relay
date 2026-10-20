import Foundation

/// One snapshot of a machine's general load, as sampled by the provider.
/// Every field beyond load/memory is best-effort: a remote that can't
/// report it (missing tool, unusual OS) simply leaves it nil/empty.
public struct MachineLoadSample: Sendable, Equatable {
    public struct GPU: Sendable, Equatable {
        public var name: String
        /// Utilization, 0...1.
        public var utilization: Double
        public var memoryUsedBytes: Int64
        public var memoryTotalBytes: Int64
        public var temperatureC: Int?

        public init(name: String, utilization: Double, memoryUsedBytes: Int64, memoryTotalBytes: Int64, temperatureC: Int? = nil) {
            self.name = name
            self.utilization = utilization
            self.memoryUsedBytes = memoryUsedBytes
            self.memoryTotalBytes = memoryTotalBytes
            self.temperatureC = temperatureC
        }
    }

    public struct Process: Sendable, Equatable {
        public var name: String
        /// Percent of one core (can exceed 100 on multi-threaded work).
        public var cpuPercent: Double
        /// Percent of physical memory.
        public var memoryPercent: Double

        public init(name: String, cpuPercent: Double, memoryPercent: Double) {
            self.name = name
            self.cpuPercent = cpuPercent
            self.memoryPercent = memoryPercent
        }
    }

    public var date: Date
    /// `uname -s` (e.g. "Darwin", "Linux").
    public var os: String
    public var cores: Int
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var memoryTotalBytes: Int64
    public var memoryUsedBytes: Int64
    public var swapTotalBytes: Int64?
    public var swapUsedBytes: Int64?
    /// Busy fraction across all cores over the last interval, 0...1.
    public var cpuBusy: Double?
    /// The filesystem holding the remote home directory.
    public var diskTotalBytes: Int64?
    public var diskUsedBytes: Int64?
    public var uptimeSeconds: Int?
    public var gpus: [GPU]
    /// Busiest processes, busiest first. Only reported by detailed sampling.
    public var processes: [Process]

    public init(
        date: Date, os: String, cores: Int,
        load1: Double, load5: Double, load15: Double,
        memoryTotalBytes: Int64, memoryUsedBytes: Int64,
        swapTotalBytes: Int64? = nil, swapUsedBytes: Int64? = nil,
        cpuBusy: Double? = nil,
        diskTotalBytes: Int64? = nil, diskUsedBytes: Int64? = nil,
        uptimeSeconds: Int? = nil,
        gpus: [GPU] = [], processes: [Process] = []
    ) {
        self.date = date
        self.os = os
        self.cores = cores
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.cpuBusy = cpuBusy
        self.diskTotalBytes = diskTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.uptimeSeconds = uptimeSeconds
        self.gpus = gpus
        self.processes = processes
    }

    /// 1-minute load per core: 1.0 means exactly as much runnable work as
    /// cores; above that, work is queueing.
    public var loadPerCore: Double { load1 / Double(max(cores, 1)) }

    public var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(max(Double(memoryUsedBytes) / Double(memoryTotalBytes), 0), 1)
    }

    public var loadLevel: MachineLoadLevel { MachineLoadLevel(loadPerCore: loadPerCore) }
    public var memoryLevel: MachineLoadLevel { MachineLoadLevel(memoryFraction: memoryFraction) }
}

/// Traffic-light classification for the toolbar donuts.
public enum MachineLoadLevel: Int, Sendable, Comparable {
    case normal, elevated, critical

    public init(loadPerCore: Double) {
        switch loadPerCore {
        case ..<0.7: self = .normal
        case ..<1.0: self = .elevated
        default: self = .critical
        }
    }

    public init(memoryFraction: Double) {
        switch memoryFraction {
        case ..<0.75: self = .normal
        case ..<0.9: self = .elevated
        default: self = .critical
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
