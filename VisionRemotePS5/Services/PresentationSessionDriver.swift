import Foundation

/// App-owned execution of the coordinator's control-plane effects. No frame,
/// decoder, audio or input tick is dispatched through this object.
@MainActor
final class PresentationSessionDriver {
    typealias Coordinator = PresentationCoordinator
    typealias Lease = Coordinator.LeaseID
    typealias Surface = Coordinator.Surface
    typealias Operation = Coordinator.Operation

    enum TransportEvent: Sendable {
        case connecting, negotiating
        case running(MetricSessionID)
        case failed(String)
    }

    struct Environment {
        var serviceIsQuiescent: @MainActor () -> Bool
        var start: @MainActor (Lease, @escaping @MainActor () -> Bool,
                              @escaping @MainActor @Sendable (TransportEvent) -> Void) async throws -> Void
        var requestStop: @MainActor () -> Void
        var waitForStop: @MainActor () async -> Void
        var prepareDelivery: @MainActor () -> Void
        var endDelivery: @MainActor () -> Void
        var openWindow: @MainActor (Surface) -> Void
        var closeWindow: @MainActor (Surface) -> Void
        var transportStatus: @MainActor (Lease, TransportEvent) -> Void
        var didEnd: @MainActor (Lease, Coordinator.Reason) -> Void
        var didUpdate: @MainActor () -> Void = {}
        /// Atomically replaces the renderer's admission owner without clearing
        /// the frame, generation or settings. Nil revokes all new acquisitions.
        /// This is synchronous so retirement cannot precede the gate transfer.
        var selectConsumer: @MainActor (Surface?) -> Void = { _ in }
        // The app supplies the actual OS actions; host tests suspend adapters.
        var openImmersion: (@MainActor (Operation, Surface) async -> Coordinator.OpenResult)? = nil
        var dismissImmersion: (@MainActor (Operation) async -> Void)? = nil
        var sleepUntil: @MainActor (TimeInterval) async throws -> Void = { due in
            let remaining = max(0, due - ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 10) * 1_000_000_000))
        }
    }

    let coordinator: Coordinator
    private let environment: Environment
    private(set) var activeLease: Lease?
    private var startupTask: Task<Void, Never>?
    private var startupLease: Lease?
    private var stoppingTask: Task<Void, Never>?
    private var stoppingLease: Lease?
    private var operationTask: Task<Void, Never>?
    private var operation: Operation?
    private var timerTask: Task<Void, Never>?
    private var timer: Coordinator.Deadline?
    private var windows: Set<Surface> = []
    private var prepared: Set<Surface> = []
    private var deliveryLease: Lease?

    init(coordinator: Coordinator, environment: Environment) {
        self.coordinator = coordinator
        self.environment = environment
    }

    var isBusy: Bool { activeLease != nil }
    var preparedSurfaceCount: Int { prepared.count }
    func ownsWindow(_ surface: Surface) -> Bool { windows.contains(surface) && surface.lease == activeLease }
    func isCurrent(_ lease: Lease) -> Bool {
        coordinator.lease == lease && coordinator.state != .terminating
    }

    @discardableResult
    func startSession() -> Coordinator.Output {
        if isBusy { return .init(rejection: .busy) }
        return send(.start(serviceIsQuiescent: environment.serviceIsQuiescent()))
    }

    func windowMounted(_ surface: Surface) {
        guard ownsWindow(surface) else { return }
        send(.windowMounted(surface))
    }

    /// Registration/focus preparation may precede the service's generation.
    /// This does not certify a physical frame or controller event was delivered.
    func consumerPrepared(_ surface: Surface) {
        guard isCurrent(surface.lease), surface == coordinator.window
                || surface == coordinator.immersiveSurface else { return }
        prepared.insert(surface)
        if let generation = coordinator.generation { send(.consumerReady(surface, generation)) }
    }

    func surfaceDetached(_ surface: Surface) {
        prepared.remove(surface)
        windows.remove(surface)
        send(.surfaceDetached(surface))
    }

    func terminate() {
        if let lease = activeLease { send(.terminate(lease, .user)) }
    }

    @discardableResult
    func send(_ event: Coordinator.Event) -> Coordinator.Output {
        if case .start = event, isBusy { return .init(rejection: .busy) }
        let output = coordinator.send(event)
        // OS completion may precede (or replace) a visual disappearance callback.
        // Keep only current participants, rather than an ever-growing history.
        prepared.formIntersection([coordinator.window, coordinator.immersiveSurface].compactMap { $0 })
        if activeLease == nil {
            activeLease = coordinator.lease
            // A failed initial deadline can reserve and terminate within one
            // reducer call. Its terminal effect still owns app cleanup.
            if activeLease == nil {
                for case .sessionEnded(let lease, _) in output.effects { activeLease = lease }
            }
        }
        for effect in output.effects { execute(effect) }
        environment.didUpdate()
        return output
    }

    private func execute(_ effect: Coordinator.Effect) {
        switch effect {
        case .requestWindow(let surface):
            guard isCurrent(surface.lease), coordinator.window == surface else { return }
            windows.insert(surface)
            environment.openWindow(surface)

        case .startTransport(let lease):
            guard startupLease == nil, coordinator.mayStartTransport(lease) else {
                // A command invalidated before execution still has to settle.
                if coordinator.lease == lease, coordinator.state == .terminating {
                    send(.startupSettled(lease))
                }
                return
            }
            startupLease = lease
            startupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard self.coordinator.mayStartTransport(lease) else { throw CancellationError() }
                    self.deliveryLease = lease
                    self.environment.prepareDelivery()
                    try Task.checkCancellation()
                    guard self.coordinator.mayStartTransport(lease) else { throw CancellationError() }
                    try await self.environment.start(lease, { [weak self] in
                        self?.coordinator.mayStartTransport(lease) == true && !Task.isCancelled
                    }, { [weak self] event in
                        self?.receive(event, lease: lease)
                    })
                } catch {
                    if self.isCurrent(lease) {
                        self.receive(.failed(error.localizedDescription), lease: lease)
                    }
                }
                if self.startupLease == lease {
                    self.startupLease = nil
                    self.startupTask = nil
                }
                self.send(.startupSettled(lease))
            }

        case .cancelStartup(let lease):
            if startupLease == lease { startupTask?.cancel() }

        case .stopTransport(let lease):
            guard coordinator.lease == lease, coordinator.state == .terminating,
                  stoppingLease == nil else { return }
            stoppingLease = lease
            let pendingStartup = startupTask
            // Stop input/audio/video admission promptly, then join the complete
            // startup before inspecting the latest service teardown task.
            environment.requestStop()
            stoppingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await pendingStartup?.value
                await self.environment.waitForStop()
                if self.stoppingLease == lease {
                    self.stoppingLease = nil
                    self.stoppingTask = nil
                }
                self.send(.transportStopped(lease))
            }

        case .openImmersion(let operation, let surface):
            guard coordinator.pendingOperation == operation else { return }
            guard isCurrent(operation.lease), coordinator.state == .opening else {
                // The OS action was never invoked. This is not cancellation of
                // an in-flight action; that task remains owned below.
                if self.operation == nil { send(.openCompleted(operation, .userCancelled)) }
                return
            }
            guard self.operation == nil else { return }
            guard let open = environment.openImmersion, environment.dismissImmersion != nil else {
                send(.openCompleted(operation, .error))
                return
            }
            self.operation = operation
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Stop may have arrived between command issuance and task entry.
                let result: Coordinator.OpenResult
                if self.isCurrent(operation.lease), self.coordinator.state == .opening {
                    result = await open(operation, surface)
                } else { result = .userCancelled }
                self.operation = nil
                self.operationTask = nil
                self.send(.openCompleted(operation, result))
            }

        case .dismissImmersion(let operation):
            guard coordinator.pendingOperation == operation, self.operation == nil,
                  let dismiss = environment.dismissImmersion else { return }
            self.operation = operation
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await dismiss(operation)
                self.operation = nil
                self.operationTask = nil
                self.send(.dismissCompleted(operation))
            }

        case .selectConsumer(let previous, let selected):
            // An earlier effect can reenter the driver and replace this choice.
            // Never replay an obsolete grant or let old cleanup revoke a new S.
            guard coordinator.selectedSurface == selected else { return }
            if let selected {
                guard isCurrent(selected.lease), activeLease == selected.lease else { return }
            } else {
                // Reconciliation may already have cleared coordinator.lease;
                // the driver retains S until every terminal effect has drained.
                guard let previous, previous.lease == activeLease else { return }
            }
            environment.selectConsumer(selected)

        case .retireWindow(let permit):
            guard coordinator.retirement == permit, permit.surface.lease == activeLease else { return }
            prepared.remove(permit.surface)
            environment.closeWindow(permit.surface)

        case .scheduleDeadline(let deadline):
            guard coordinator.deadline == deadline, coordinator.lease == deadline.lease else { return }
            timerTask?.cancel()
            timer = deadline
            timerTask = Task { @MainActor [weak self, sleep = environment.sleepUntil] in
                do { try await sleep(deadline.due) } catch {
                    guard !Task.isCancelled, let self, self.timer == deadline else { return }
                    self.timer = nil
                    self.timerTask = nil
                    self.send(.terminate(deadline.lease, .clockUnavailable))
                    return
                }
                guard !Task.isCancelled, let self, self.timer == deadline else { return }
                self.timer = nil
                self.timerTask = nil
                self.send(.deadlineExpired(deadline))
            }

        case .cancelDeadline(let deadline):
            if timer == deadline {
                timerTask?.cancel()
                timerTask = nil
                timer = nil
            }

        case .sessionEnded(let lease, let reason):
            guard activeLease == lease, coordinator.lease == nil else { return }
            // Keep the driver busy throughout synchronous cleanup. In particular
            // an old disable must finish before a new session can enable delivery.
            if deliveryLease == lease {
                environment.endDelivery()
                deliveryLease = nil
            }
            let closing = windows.filter { $0.lease == lease }
            windows.subtract(closing)
            prepared.removeAll()
            for surface in closing { environment.closeWindow(surface) }
            activeLease = nil
            environment.didEnd(lease, reason)
        }
    }

    private func receive(_ event: TransportEvent, lease: Lease) {
        guard isCurrent(lease) else { return }
        switch event {
        case .connecting, .negotiating:
            guard coordinator.transport == .starting else { return }
            environment.transportStatus(lease, event)
        case .running(let generation):
            let output = send(.transportRunning(lease, generation))
            guard output.rejection == nil, isCurrent(lease) else { return }
            environment.transportStatus(lease, event)
            for surface in prepared where surface.lease == lease {
                send(.consumerReady(surface, generation))
            }
        case .failed:
            environment.transportStatus(lease, event)
            send(.terminate(lease, .transportFailure))
        }
    }
}
