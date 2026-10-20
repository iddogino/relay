import Foundation
import Testing
@testable import RelayCore

@Suite("machine load parsing")
struct MachineLoadParserTests {
    private let linuxBlock = """
    RLOAD_BEGIN
    os=Linux
    ncpu=48
    load=0.57 1.15 1.51
    mem=201925042176 27707326464
    swap=8589930496 671744
    cpu=12
    uptime=154394
    disk=1920641288 1342075576
    gpu=0 15 97887 40 NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition
    gpu=[N/A] 15 97887 [N/A] Broken GPU
    proc=9.1 0.4 beam.smp
    proc=21.7 0.3 node
    RLOAD_END

    """

    private let macBlock = """
    RLOAD_BEGIN
    os=Darwin
    ncpu=10
    load= 71.38 155.59 366.89
    mem=17179869184 15000000000
    swap=20401094656 19748474880
    uptime=3573000
    cpu=280
    disk=971350180 612341664
    proc= 53.3  1.8 /Users/me/Library/Developer/CoreSimulator/Devices/X/Gamut.app/Gamut
    proc= 21.9  0.3 (backboardd)
    proc= 18.9  0.1 /Library/Developer/iOS 26.5.simruntime/usr/libexec/SimMetal Host
    RLOAD_END

    """

    @Test func parsesLinuxSample() throws {
        var parser = MachineLoadParser()
        let samples = parser.feed(Data(linuxBlock.utf8))
        let sample = try #require(samples.first)
        #expect(samples.count == 1)
        #expect(sample.os == "Linux")
        #expect(sample.cores == 48)
        #expect(sample.load1 == 0.57 && sample.load5 == 1.15 && sample.load15 == 1.51)
        #expect(abs(sample.loadPerCore - 0.57 / 48) < 1e-9)
        #expect(sample.loadLevel == .normal)
        #expect(sample.memoryTotalBytes == 201_925_042_176)
        #expect(sample.memoryLevel == .normal)
        #expect(sample.swapUsedBytes == 671_744)
        #expect(sample.cpuBusy == 0.012)
        #expect(sample.uptimeSeconds == 154_394)
        #expect(sample.diskTotalBytes == Int64(1_920_641_288) * 1024)
        // The [N/A] GPU is dropped, not misparsed.
        #expect(sample.gpus.count == 1)
        #expect(sample.gpus.first?.name == "NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition")
        #expect(sample.gpus.first?.memoryTotalBytes == 97887 << 20)
        #expect(sample.gpus.first?.temperatureC == 40)
        // Busiest first.
        #expect(sample.processes.map(\.name) == ["node", "beam.smp"])
    }

    @Test func parsesMacSampleWithPathsContainingSpaces() throws {
        var parser = MachineLoadParser()
        let sample = try #require(parser.feed(Data(macBlock.utf8)).first)
        #expect(sample.load1 == 71.38)
        #expect(sample.loadLevel == .critical)
        #expect(sample.memoryLevel == .elevated)
        #expect(sample.cpuBusy == 0.28)
        #expect(sample.gpus.isEmpty)
        #expect(sample.processes.map(\.name) == ["Gamut", "backboardd", "SimMetal Host"])
        #expect(sample.processes.first?.cpuPercent == 53.3)
    }

    @Test func handlesSplitReadsAndMultipleBlocks() {
        var parser = MachineLoadParser()
        let stream = Data((linuxBlock + macBlock).utf8)
        var samples: [MachineLoadSample] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let next = min(index + 7, stream.endIndex)
            samples += parser.feed(stream[index..<next])
            index = next
        }
        #expect(samples.map(\.os) == ["Linux", "Darwin"])
    }

    @Test func dropsIncompleteOrMalformedBlocks() {
        var parser = MachineLoadParser()
        let noMemory = "RLOAD_BEGIN\nos=Linux\nncpu=4\nload=1 1 1\nRLOAD_END\n"
        let zeroCores = "RLOAD_BEGIN\nncpu=0\nload=1 1 1\nmem=100 50\nRLOAD_END\n"
        let unterminated = "RLOAD_BEGIN\nncpu=4\nload=1 1 1\nmem=100 50\n"
        #expect(parser.feed(Data((noMemory + zeroCores + unterminated).utf8)).isEmpty)
        // A fresh BEGIN discards the unterminated block.
        let good = "RLOAD_BEGIN\nncpu=4\nload=1 1 1\nmem=100 50\nRLOAD_END\n"
        #expect(parser.feed(Data(good.utf8)).count == 1)
    }

    @Test func levelThresholds() {
        #expect(MachineLoadLevel(loadPerCore: 0.5) == .normal)
        #expect(MachineLoadLevel(loadPerCore: 0.8) == .elevated)
        #expect(MachineLoadLevel(loadPerCore: 1.0) == .critical)
        #expect(MachineLoadLevel(memoryFraction: 0.74) == .normal)
        #expect(MachineLoadLevel(memoryFraction: 0.85) == .elevated)
        #expect(MachineLoadLevel(memoryFraction: 0.95) == .critical)
    }
}

@Suite("machine load script")
struct MachineLoadScriptTests {
    @Test func clampsParameters() {
        let script = SSHTmuxScripts.machineLoad(interval: 0, detailed: false, iterations: -5)
        #expect(script.contains("interval=2\n"))
        #expect(script.contains("n=1\n"))
        #expect(script.contains("detail=0\n"))
    }

    /// Runs the real script against this Mac (the Darwin code path; Linux
    /// is covered live by the E2E suite).
    @Test func samplesThisMachine() async throws {
        let result = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-s"],
            stdin: SSHTmuxScripts.machineLoad(interval: 2, detailed: true, iterations: 2),
            timeout: .seconds(30)
        )
        #expect(result.exitCode == 0)
        var parser = MachineLoadParser()
        let samples = parser.feed(Data(result.stdout.utf8))
        #expect(samples.count == 2)
        let sample = try #require(samples.last)
        #expect(sample.cores == ProcessInfo.processInfo.activeProcessorCount)
        #expect(sample.memoryTotalBytes == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(sample.memoryUsedBytes > 0)
        #expect(sample.cpuBusy != nil)
        #expect(sample.swapTotalBytes != nil)
        #expect((sample.diskTotalBytes ?? 0) > 0)
        #expect((sample.uptimeSeconds ?? 0) > 0)
        #expect(!sample.processes.isEmpty)
        #expect(!sample.processes.contains { $0.name == "ps" })
    }
}
