import Foundation

protocol GatewayRetrySleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemGatewayRetrySleeper: GatewayRetrySleeping, Sendable {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct GatewayBackoffPolicy: Equatable, Sendable {
    let delays: [Duration]

    init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]) {
        self.delays = delays
    }
}

protocol GatewayCoordinating: Actor {
    func updates() -> AsyncStream<GatewayUpdate>
    func start() async
    func refresh() async
    func suspend() async
    func resume() async
    func stop() async
}

actor GatewayCoordinator: GatewayCoordinating {
    private let sessionLoader: any DesktopSessionLoading
    private let rosterClient: any GatewayRosterFetching
    private let eventStream: any GatewayEventStreaming
    private let retrySleeper: any GatewayRetrySleeping
    private let backoff: GatewayBackoffPolicy
    private let rosterCorrectionInterval: Duration
    private let logger: any GatewayLogging
    private var rosterStore = BotRosterStore()

    private var session: DesktopSession?
    private var connectionState: GatewayConnectionState = .idle
    private var currentRoster: RosterSnapshot = .empty
    private var subscribers: [UUID: AsyncStream<GatewayUpdate>.Continuation] = [:]
    private var connectionTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var requestCancellationTask: Task<Void, Never>?
    private var requestCancellationID: UUID?
    private var connectionGeneration: UInt64 = 0
    private var isSuspended = false
    private var isStopped = false

    /// Live production assembly. It performs only descriptor/Keychain reads,
    /// `POST /api/listAgents`, and a read-only `/events` subscription.
    init(
        sessionLoader: any DesktopSessionLoading = DesktopSessionLoader(),
        rosterClient: any GatewayRosterFetching = GatewayHTTPClient(),
        eventStream: any GatewayEventStreaming = GatewayEventStream(),
        retrySleeper: any GatewayRetrySleeping = SystemGatewayRetrySleeper(),
        backoff: GatewayBackoffPolicy = GatewayBackoffPolicy(),
        rosterCorrectionInterval: Duration = .seconds(120),
        logger: any GatewayLogging = GatewayLogger()
    ) {
        self.sessionLoader = sessionLoader
        self.rosterClient = rosterClient
        self.eventStream = eventStream
        self.retrySleeper = retrySleeper
        self.backoff = backoff
        self.rosterCorrectionInterval = rosterCorrectionInterval
        self.logger = logger
    }

    func updates() -> AsyncStream<GatewayUpdate> {
        let id = UUID()
        let state = connectionState
        let roster = currentRoster
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(.connection(state))
            continuation.yield(.roster(roster))
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func start() async {
        guard connectionTask == nil, !isSuspended, !isStopped else { return }
        if let requestCancellationTask {
            await requestCancellationTask.value
        }
        guard connectionTask == nil, !isSuspended, !isStopped else { return }
        publish(.connection(.connecting))
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let generationRosterStore = BotRosterStore()
        rosterStore = generationRosterStore
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop(generation: generation, rosterStore: generationRosterStore)
        }
    }

    func refresh() async {
        guard !isSuspended, !isStopped else { return }
        // A user-visible retry must restore the complete live pipeline. A one-shot
        // roster refresh can report "connected" while leaving SSE and correction
        // tasks stopped after the previous retry budget was exhausted.
        await restart(reloadSession: true)
    }

    func suspend() async {
        isSuspended = true
        connectionGeneration &+= 1
        connectionTask?.cancel()
        correctionTask?.cancel()
        connectionTask = nil
        correctionTask = nil
        publish(.connection(.offline(.suspended)))
        await cancelRosterRequests()
    }

    func resume() async {
        guard isSuspended, !isStopped else { return }
        if let requestCancellationTask {
            await requestCancellationTask.value
        }
        guard isSuspended, !isStopped else { return }
        isSuspended = false
        session = nil
        await start()
    }

    func stop() async {
        isStopped = true
        isSuspended = true
        connectionGeneration &+= 1
        connectionTask?.cancel()
        correctionTask?.cancel()
        connectionTask = nil
        correctionTask = nil
        session = nil
        connectionState = .idle
        await cancelRosterRequests()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func runConnectionLoop(generation: UInt64, rosterStore: BotRosterStore) async {
        defer {
            if generation == connectionGeneration {
                connectionTask = nil
                correctionTask?.cancel()
                correctionTask = nil
            }
        }

        let delays = backoff.delays
        for attempt in 0...delays.count {
            guard generation == connectionGeneration, !Task.isCancelled, !isSuspended else { return }
            do {
                let activeSession = try await loadSessionIfNeeded(generation: generation)
                let records = try await rosterClient.listAgents(session: activeSession)
                try Task.checkCancellation()
                guard generation == connectionGeneration, !isSuspended else { return }
                let roster = await rosterStore.replace(with: records)
                guard generation == connectionGeneration, !isSuspended else { return }
                currentRoster = roster
                publish(.roster(roster))
                publish(.connection(roster.bots.isEmpty ? .offline(.noBots) : .connected))
                logger.log(.info, "Gateway roster connected")

                startRosterCorrection(session: activeSession, generation: generation, rosterStore: rosterStore)
                try await consumeEvents(session: activeSession, generation: generation, rosterStore: rosterStore)
                throw GatewayFailure.transport(operation: "events")
            } catch is CancellationError {
                return
            } catch let failure as GatewayFailure {
                guard generation == connectionGeneration, !isSuspended else { return }
                correctionTask?.cancel()
                correctionTask = nil
                if case .unauthorized = failure { session = nil }
                publish(.connection(.offline(failure.offlineReason)))
                guard Self.shouldRetry(failure), attempt < delays.count else { return }
                do {
                    try await retrySleeper.sleep(for: delays[attempt])
                } catch {
                    return
                }
            } catch {
                guard generation == connectionGeneration, !isSuspended else { return }
                correctionTask?.cancel()
                correctionTask = nil
                logger.log(.error, "Gateway recovery failure")
                publish(.connection(.offline(.network)))
                guard attempt < delays.count else { return }
                do {
                    try await retrySleeper.sleep(for: delays[attempt])
                } catch {
                    return
                }
            }
        }
    }

    private func loadSessionIfNeeded(generation: UInt64) async throws -> DesktopSession {
        if let session { return session }
        publish(.connection(.connecting))
        let loaded = try await sessionLoader.load()
        try Task.checkCancellation()
        guard generation == connectionGeneration, !isSuspended else {
            throw CancellationError()
        }
        session = loaded
        return loaded
    }

    private func consumeEvents(
        session: DesktopSession,
        generation: UInt64,
        rosterStore: BotRosterStore
    ) async throws {
        for try await event in eventStream.events(session: session) {
            try Task.checkCancellation()
            guard generation == connectionGeneration, !isSuspended else { throw CancellationError() }
            if event == .connected {
                logger.log(.info, "Gateway event stream connected")
                // SSE recovery is followed by a roster correction. The HTTP
                // actor coalesces this with any concurrent low-frequency refresh.
                let records = try await rosterClient.listAgents(session: session)
                try Task.checkCancellation()
                guard generation == connectionGeneration, !isSuspended else { throw CancellationError() }
                let roster = await rosterStore.replace(with: records)
                guard generation == connectionGeneration, !isSuspended else { throw CancellationError() }
                currentRoster = roster
                publish(.roster(roster))
                publish(.connection(roster.bots.isEmpty ? .offline(.noBots) : .connected))
            } else {
                let roster = await rosterStore.apply(event)
                guard generation == connectionGeneration, !isSuspended else { throw CancellationError() }
                currentRoster = roster
                publish(.event(event))
                publish(.roster(roster))
            }
        }
    }

    private func startRosterCorrection(
        session: DesktopSession,
        generation: UInt64,
        rosterStore: BotRosterStore
    ) {
        correctionTask?.cancel()
        correctionTask = Task { [weak self, rosterClient, rosterCorrectionInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: rosterCorrectionInterval)
                    let records = try await rosterClient.listAgents(session: session)
                    await self?.acceptCorrection(records, generation: generation, rosterStore: rosterStore)
                } catch is CancellationError {
                    return
                } catch let failure as GatewayFailure {
                    await self?.handleCorrectionFailure(failure, generation: generation)
                } catch {
                    // The primary SSE loop owns recovery. A correction failure
                    // is non-fatal and never blocks App/UI actors.
                }
            }
        }
    }

    private func acceptCorrection(
        _ records: [GatewayAgentRecord],
        generation: UInt64,
        rosterStore: BotRosterStore
    ) async {
        guard generation == connectionGeneration, !isSuspended else { return }
        let roster = await rosterStore.replace(with: records)
        guard generation == connectionGeneration, !isSuspended, !isStopped else { return }
        currentRoster = roster
        publish(.roster(roster))
    }

    private func handleCorrectionFailure(_ failure: GatewayFailure, generation: UInt64) async {
        guard generation == connectionGeneration, case .unauthorized = failure else { return }
        publish(.connection(.offline(.unauthorized)))
        await restart(reloadSession: true)
    }

    private func restart(reloadSession: Bool) async {
        guard !isStopped else { return }
        connectionGeneration &+= 1
        connectionTask?.cancel()
        correctionTask?.cancel()
        connectionTask = nil
        correctionTask = nil
        if reloadSession { session = nil }
        await cancelRosterRequests()
        await start()
    }

    private func cancelRosterRequests() async {
        let cancellationID = UUID()
        let cancellation = Task { [rosterClient] in
            await rosterClient.cancelPendingRequests()
        }
        requestCancellationID = cancellationID
        requestCancellationTask = cancellation
        await cancellation.value
        if requestCancellationID == cancellationID {
            requestCancellationTask = nil
            requestCancellationID = nil
        }
    }

    private func publish(_ update: GatewayUpdate) {
        if case .connection(let state) = update { connectionState = state }
        for continuation in subscribers.values { continuation.yield(update) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private static func shouldRetry(_ failure: GatewayFailure) -> Bool {
        switch failure {
        case .unauthorized, .httpStatus, .timeout, .transport, .invalidResponse:
            true
        case .descriptorMissing, .unsupportedDescriptor, .keychainDenied, .keychainUnavailable,
             .unsupportedCiphertext, .decryptionFailed, .invalidSession, .invalidURL, .cancelled:
            false
        }
    }
}
