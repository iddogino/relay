import Charts
import SwiftUI
import RelayCore

/// The toolbar machine-load pill: two small donuts (CPU load per core,
/// memory) colored by level; hovering opens a popover with history graphs
/// and extra metrics (and switches sampling to its fast, detailed mode).
struct MachineLoadBadge: View {
    @Bindable var model: AppModel
    let machineName: String
    let history: [MachineLoadSample]

    @State private var pillHovered = false
    @State private var popoverHovered = false
    @State private var popoverShown = false

    private var latest: MachineLoadSample? { history.last }

    var body: some View {
        Button {
            popoverShown.toggle()
        } label: {
            if let latest {
                HStack(spacing: 5) {
                    LoadDonut(fraction: min(latest.loadPerCore, 1), level: latest.loadLevel)
                    LoadDonut(fraction: latest.memoryFraction, level: latest.memoryLevel)
                }
                .padding(.horizontal, 2)
            }
        }
        .accessibilityLabel(accessibilitySummary)
        .onHover { hovering in
            pillHovered = hovering
            syncPopover()
        }
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            MachineLoadPopover(machineName: machineName, history: model.selectedMachineLoad ?? history)
                .onHover { hovering in
                    popoverHovered = hovering
                    syncPopover()
                }
        }
        .onChange(of: popoverShown) { _, shown in
            model.loadDetailsVisible = shown
        }
        .onDisappear { model.loadDetailsVisible = false }
    }

    private var accessibilitySummary: String {
        guard let latest else { return "Machine load" }
        return "\(machineName): load \(latest.loadPerCore.formatted(.percent.precision(.fractionLength(0)))) of capacity, memory \(latest.memoryFraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    /// Same hover choreography as the PR pill: show on hover, close after a
    /// grace period so the pointer can travel into the popover.
    private func syncPopover() {
        if pillHovered || popoverHovered {
            popoverShown = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                if !pillHovered && !popoverHovered { popoverShown = false }
            }
        }
    }
}

private struct LoadDonut: View {
    let fraction: Double
    let level: MachineLoadLevel

    var body: some View {
        ZStack {
            Circle()
                .stroke(level.color.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.04))
                .stroke(level.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.easeInOut(duration: 0.4), value: fraction)
    }
}

extension MachineLoadLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}

struct MachineLoadPopover: View {
    let machineName: String
    let history: [MachineLoadSample]

    /// The graphs' time window.
    private static let window: TimeInterval = 15 * 60

    var body: some View {
        if let latest = history.last {
            content(latest)
        }
    }

    private func content(_ latest: MachineLoadSample) -> some View {
        let recent = history.filter { latest.date.timeIntervalSince($0.date) <= Self.window }
        // One time axis for every graph so they line up for comparison: up
        // to `window` wide, but a young history fills the width instead of
        // hugging the right edge (two minutes minimum so early samples
        // don't stretch).
        let span = min(max(latest.date.timeIntervalSince(recent.first?.date ?? latest.date), 120), Self.window)
        let xDomain = latest.date.addingTimeInterval(-span)...latest.date
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machineName)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle(latest))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            MetricGraph(
                title: "Load",
                value: "\(Fmt.percent(latest.loadPerCore)) of capacity",
                detail: "\(Fmt.number(latest.load1)) on \(latest.cores) cores · 1 / 5 / 15 min: \(Fmt.number(latest.load1)) · \(Fmt.number(latest.load5)) · \(Fmt.number(latest.load15))",
                color: latest.loadLevel.color,
                points: recent.map { ($0.date, $0.loadPerCore * 100) },
                // Load is uncapped: above 100% work is queuing, and the
                // graph grows to show by how much.
                yDomain: 0...max(100, recent.map { $0.loadPerCore * 100 }.max() ?? 0) * 1.05,
                rule: (100, "100% capacity"),
                xDomain: xDomain
            )

            let cpuPoints = recent.compactMap { s in s.cpuBusy.map { (s.date, $0 * 100) } }
            if let cpu = latest.cpuBusy ?? recent.last(where: { $0.cpuBusy != nil })?.cpuBusy {
                MetricGraph(
                    title: "CPU",
                    value: Fmt.percent(cpu),
                    detail: nil,
                    color: MachineLoadLevel(loadPerCore: cpu).color,
                    points: cpuPoints,
                    yDomain: 0...100,
                    rule: nil,
                    xDomain: xDomain
                )
            }

            MetricGraph(
                title: "Memory",
                value: "\(Fmt.bytes(latest.memoryUsedBytes)) of \(Fmt.bytes(latest.memoryTotalBytes)) · \(Fmt.percent(latest.memoryFraction))",
                detail: swapText(latest),
                color: latest.memoryLevel.color,
                points: recent.map { ($0.date, $0.memoryFraction * 100) },
                yDomain: 0...100,
                rule: nil,
                xDomain: xDomain
            )

            if let total = latest.diskTotalBytes, let used = latest.diskUsedBytes, total > 0 {
                let fraction = Double(used) / Double(total)
                BarRow(
                    title: "Disk (home)",
                    value: "\(Fmt.bytes(used)) of \(Fmt.bytes(total)) · \(Fmt.percent(fraction))",
                    fraction: fraction,
                    color: MachineLoadLevel(memoryFraction: fraction).color
                )
            }

            ForEach(Array(latest.gpus.enumerated()), id: \.offset) { index, gpu in
                BarRow(
                    title: latest.gpus.count > 1 ? "GPU \(index)" : "GPU",
                    value: gpuText(gpu),
                    fraction: gpu.utilization,
                    color: MachineLoadLevel(loadPerCore: gpu.utilization).color
                )
                .help(gpu.name)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Top processes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if latest.processes.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Sampling…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 16)
                } else {
                    ForEach(ProcessGroup.top(latest.processes, limit: 5), id: \.name) { group in
                        ProcessRow(group: group, memoryTotal: latest.memoryTotalBytes)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func subtitle(_ sample: MachineLoadSample) -> String {
        var parts: [String] = []
        switch sample.os {
        case "Darwin": parts.append("macOS")
        case "": break
        default: parts.append(sample.os)
        }
        parts.append("\(sample.cores) cores")
        if let uptime = sample.uptimeSeconds, uptime > 0 {
            parts.append("up \(Fmt.duration(uptime))")
        }
        return parts.joined(separator: " · ")
    }

    private func swapText(_ sample: MachineLoadSample) -> String? {
        guard let total = sample.swapTotalBytes, let used = sample.swapUsedBytes, total > 0 else { return nil }
        return "Swap \(Fmt.bytes(used)) of \(Fmt.bytes(total))"
    }

    private func gpuText(_ gpu: MachineLoadSample.GPU) -> String {
        var text = "\(Fmt.percent(gpu.utilization)) · \(Fmt.bytes(gpu.memoryUsedBytes)) of \(Fmt.bytes(gpu.memoryTotalBytes))"
        if let temp = gpu.temperatureC { text += " · \(temp)°C" }
        return text
    }
}

private struct MetricGraph: View {
    let title: String
    let value: String
    let detail: String?
    let color: Color
    let points: [(Date, Double)]
    let yDomain: ClosedRange<Double>
    let rule: (Double, String)?
    let xDomain: ClosedRange<Date>

    /// Sampling pauses (app inactive, machine switched away) leave gaps;
    /// splitting the line there keeps it from drawing a fake straight trend.
    private var segments: [(date: Date, value: Double, segment: Int)] {
        var segment = 0
        var previous: Date?
        return points.map { date, value in
            if let previous, date.timeIntervalSince(previous) > 30 { segment += 1 }
            previous = date
            return (date, value, segment)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11).monospacedDigit())
            }
            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Base", yDomain.lowerBound),
                        yEnd: .value(title, min(point.value, yDomain.upperBound)),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(color.opacity(0.15))
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(title, min(point.value, yDomain.upperBound)),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let rule, rule.0 <= yDomain.upperBound {
                    RuleMark(y: .value("Reference", rule.0))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                            Text(rule.1)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .frame(height: 44)
            if let detail {
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BarRow: View {
    let title: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11).monospacedDigit())
            }
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(color)
                .controlSize(.small)
        }
    }
}

/// Same-named processes (simulator instances, compiler workers) merged into
/// one row with a count, so five rows show five different things.
private struct ProcessGroup {
    var name: String
    var count: Int
    var cpuPercent: Double
    var memoryPercent: Double

    static func top(_ processes: [MachineLoadSample.Process], limit: Int) -> [ProcessGroup] {
        var groups: [ProcessGroup] = []
        for process in processes {
            if let index = groups.firstIndex(where: { $0.name == process.name }) {
                groups[index].count += 1
                groups[index].cpuPercent += process.cpuPercent
                groups[index].memoryPercent += process.memoryPercent
            } else {
                groups.append(ProcessGroup(name: process.name, count: 1, cpuPercent: process.cpuPercent, memoryPercent: process.memoryPercent))
            }
        }
        return Array(groups.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}

private struct ProcessRow: View {
    let group: ProcessGroup
    let memoryTotal: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(group.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            if group.count > 1 {
                Text("×\(group.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(group.cpuPercent.formatted(.number.precision(.fractionLength(0))))%")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Text(Fmt.bytes(Int64(Double(memoryTotal) * group.memoryPercent / 100)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

private enum Fmt {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : value >= 10 ? 1 : 2)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? ""
    }
}
