//
//  SerialBrewCommandCenterReconcileTests.swift
//  BrewTests
//

@testable import BrewCLI
import BrewCore
import BrewServicesTestSupport
import Foundation
import Testing

/// Counts reconcile calls, and can block inside one so a test can observe the settling window.
private actor RecordingReconciler: BrewOperationReconciling {
    private(set) var callCount = 0
    private let onReconcile: @Sendable () async -> Void

    init(onReconcile: @escaping @Sendable () async -> Void = {}) {
        self.onReconcile = onReconcile
    }

    func reconcile() async {
        callCount += 1
        await onReconcile()
    }
}

private actor PhaseCollector {
    private(set) var phases: [BrewOperationPhase] = []

    func append(_ phase: BrewOperationPhase) {
        phases.append(phase)
    }
}

/// Runner whose behaviour is a closure of the argv, mirroring ``SerialBrewCommandCenterTests``.
private struct ReconcileClosureRunner: BrewCommandRunning {
    let body: @Sendable ([String]) async throws -> CommandOutput

    func run(executableURL _: URL, arguments: [String], options _: BrewRunOptions) async throws -> CommandOutput {
        try await body(arguments)
    }
}

private let successOutput = CommandOutput(standardOutput: "", standardError: "", terminationStatus: 0)
private let failureOutput = CommandOutput(standardOutput: "", standardError: "boom", terminationStatus: 1)

private func makeCenter(runner: any BrewCommandRunning) -> SerialBrewCommandCenter {
    let ctx = BrewCommandExecutionContext(
        commandRunner: runner,
        locator: BrewExecutableLocator(overrideURL: URL(fileURLWithPath: "/fake/brew")),
    )
    return SerialBrewCommandCenter(executionContext: ctx)
}

private func collectPhases(
    from center: SerialBrewCommandCenter,
    id: BrewOperationID,
) async -> (PhaseCollector, Task<Void, Never>) {
    let stream = await center.phaseChanges(for: id)
    let collector = PhaseCollector()
    let task = Task {
        for await phase in stream {
            await collector.append(phase)
        }
    }
    return (collector, task)
}

struct SerialBrewCommandCenterReconcileTests {
    @Test func `a mutating command reconciles before it settles`() async throws {
        let center = makeCenter(runner: ReconcileClosureRunner { _ in successOutput })
        let id = BrewOperationID(kind: .formula, name: "git")
        let reconciler = RecordingReconciler()
        await center.setReconciler(reconciler)
        let (collector, collect) = await collectPhases(from: center, id: id)
        defer { collect.cancel() }

        try await center.perform(BrewCommand(operationKind: .upgradeFormula, arguments: ["upgrade", "git"]), id: id)
        try await waitUntil { await collector.phases.count >= 4 }

        let phases: [BrewOperationPhase] = await collector.phases
        #expect(await reconciler.callCount == 1)
        #expect(phases == [.idle, .running(.upgradeFormula), .reconciling(.upgradeFormula), .idle])
    }

    @Test func `a failed mutating command still reconciles`() async throws {
        // A batch `brew upgrade a b` can exit non-zero having upgraded `a`, so the inventory is stale
        // exactly when the command failed.
        let center = makeCenter(runner: ReconcileClosureRunner { _ in failureOutput })
        let id = BrewOperationID.bulkUpgrade(.all)
        let reconciler = RecordingReconciler()
        await center.setReconciler(reconciler)
        let (collector, collect) = await collectPhases(from: center, id: id)
        defer { collect.cancel() }

        await #expect(throws: (any Error).self) {
            try await center.perform(BrewCommand(operationKind: .upgradeAll, arguments: ["upgrade"]), id: id)
        }
        try await waitUntil { await collector.phases.count >= 4 }

        let phases: [BrewOperationPhase] = await collector.phases
        #expect(await reconciler.callCount == 1)
        #expect(phases[2] == .reconciling(.upgradeAll))
        guard case .failed = phases[3] else {
            Issue.record("expected the failure to be published after the reconcile")
            return
        }
    }

    @Test func `read-only work does not reconcile`() async throws {
        let center = makeCenter(runner: ReconcileClosureRunner { _ in successOutput })
        let id = BrewOperationID.maintenance(token: "doctor", displayCommand: "brew doctor")
        let reconciler = RecordingReconciler()
        await center.setReconciler(reconciler)
        let (collector, collect) = await collectPhases(from: center, id: id)
        defer { collect.cancel() }

        _ = try await center.capture(BrewCommand(operationKind: .doctorRead, arguments: ["doctor"]), id: id)
        try await waitUntil { await collector.phases.count >= 3 }

        let phases: [BrewOperationPhase] = await collector.phases
        #expect(await reconciler.callCount == 0)
        #expect(phases == [.idle, .running(.doctorRead), .idle])
    }

    @Test func `with no reconciler registered the operation settles as before`() async throws {
        let center = makeCenter(runner: ReconcileClosureRunner { _ in successOutput })
        let id = BrewOperationID(kind: .formula, name: "git")
        let (collector, collect) = await collectPhases(from: center, id: id)
        defer { collect.cancel() }

        try await center.perform(BrewCommand(operationKind: .upgradeFormula, arguments: ["upgrade", "git"]), id: id)
        try await waitUntil { await collector.phases.count >= 3 }

        let phases: [BrewOperationPhase] = await collector.phases
        #expect(phases == [.idle, .running(.upgradeFormula), .idle])
    }

    @Test func `the terminal phase is withheld until the reconcile finishes`() async throws {
        let center = makeCenter(runner: ReconcileClosureRunner { _ in successOutput })
        let id = BrewOperationID(kind: .formula, name: "git")
        let gate = TestGate()
        let reconciler = RecordingReconciler { await gate.wait() }
        await center.setReconciler(reconciler)

        let run = Task {
            try await center.perform(
                BrewCommand(operationKind: .uninstallFormula, arguments: ["uninstall", "git"]),
                id: id,
            )
        }
        try await waitUntil { await center.phase(for: id) == .reconciling(.uninstallFormula) }

        await gate.open()
        try await run.value
        #expect(await center.phase(for: id) == .idle)
    }
}
