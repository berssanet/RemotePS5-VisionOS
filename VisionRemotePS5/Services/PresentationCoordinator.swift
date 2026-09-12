import Foundation

/// Control-plane reducer for the 02.01 contract. AppState owns one instance.
/// PresentationSessionDriver executes effects through app/scene adapters.
/// Effects are commands, not completed work. Before acting, the driver must
/// validate the current S/phase/surface/O/permit, execute or discard each issued
/// command once, and revalidate after awaits. A skipped, never-invoked open can
/// acknowledge cancellation; an invoked open must return its actual result.
/// Deadline scheduling replaces the timer for that token rather than queuing it.
@MainActor
final class PresentationCoordinator {
    struct LeaseID: Hashable, Codable, Sendable {
        let value: UUID
        init(value: UUID = UUID()) { self.value = value }
    }
    struct Operation: Hashable, Sendable {
        let lease: LeaseID
        let id = UUID()
    }
    enum SurfaceKind: Hashable, Codable, Sendable { case window, immersive }
    struct Surface: Hashable, Codable, Sendable {
        let lease: LeaseID
        let kind: SurfaceKind
        let id: UUID
        init(lease: LeaseID, kind: SurfaceKind, id: UUID = UUID()) {
            self.lease = lease
            self.kind = kind
            self.id = id
        }
    }
    struct Retirement: Equatable, Sendable {
        let operation: Operation
        let surface: Surface
    }
    enum State: CaseIterable, Equatable, Sendable {
        case idle, starting, windowed, opening, immersive, recoveringWindow
        case closing, error, terminating, terminated
    }
    enum TransportPhase: Equatable, Sendable { case reserved, starting, running, stopping, ended }
    enum OpenResult: CaseIterable, Sendable { case opened, userCancelled, error, unknown }
    enum Reason: Equatable, Sendable {
        case user, transportFailure, background, windowLost, windowTimeout
        case openFailed, readinessFailed, unknownOpenResult, clockUnavailable
    }
    enum AppPhase: Sendable { case active, inactive, background }
    enum DeadlineKind: Equatable, Sendable { case initialWindow, fallbackWindow, immersiveReady }
    struct Deadline: Equatable, Sendable {
        let lease: LeaseID
        let kind: DeadlineKind
        let due: TimeInterval
        let id = UUID()
    }
    enum Event: Sendable {
        case start(serviceIsQuiescent: Bool)
        case windowMounted(Surface)
        case transportRunning(LeaseID, MetricSessionID)
        case startupSettled(LeaseID)
        case transportStopped(LeaseID)
        case enterImmersion(LeaseID)
        case returnToWindow(LeaseID)
        case consumerReady(Surface, MetricSessionID)
        case openCompleted(Operation, OpenResult)
        case dismissCompleted(Operation)
        case surfaceDetached(Surface)
        case readinessFailed(Surface)
        case terminate(LeaseID, Reason)
        case appPhase(AppPhase)
        case scenePhase(AppPhase)
        case deadlineExpired(Deadline)
    }
    enum Effect: Equatable, Sendable {
        case requestWindow(Surface)
        case startTransport(LeaseID)
        /// Must settle the entire issued startup, even if still awaiting auth.
        case cancelStartup(LeaseID)
        /// Ack only after startup can no longer acquire resources and teardown joins.
        case stopTransport(LeaseID)
        case openImmersion(Operation, Surface)
        case dismissImmersion(Operation)
        /// Revoke `from` before granting `to`. Neither operation changes G.
        case selectConsumer(from: Surface?, to: Surface?)
        case retireWindow(Retirement)
        case scheduleDeadline(Deadline)
        case cancelDeadline(Deadline)
        case sessionEnded(LeaseID, Reason)
    }
    enum Rejection: Equatable, Sendable { case busy, notReady, stale, unsupported }
    struct Output: Equatable, Sendable {
        var effects: [Effect] = []
        var rejection: Rejection?
    }

    private(set) var state: State = .idle
    private(set) var lease: LeaseID?
    private(set) var generation: MetricSessionID?
    private(set) var transport: TransportPhase = .ended
    private(set) var selectedSurface: Surface?
    private(set) var window: Surface?
    private(set) var immersiveSurface: Surface?
    private(set) var retirement: Retirement?
    private(set) var deadline: Deadline?
    private(set) var reason: Reason?

    private enum Awaited { case open, dismiss }
    private enum Presence { case absent, open, unknown }
    private struct Slot {
        let operation: Operation
        var awaited: Awaited?
    }
    private var slot: Slot?
    private var presence: Presence = .absent
    private var windowIsMounted = false
    private var windowIsReady = false
    private var immersiveIsReady = false
    private var abortOpening = false
    private var startupIssued = false
    private var startupIsSettled = true
    private var transportIsSettled = true
    private let now: () -> TimeInterval
    private var lastTime: TimeInterval = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var pendingOperation: Operation? { slot?.operation }

    /// The startup driver checks before authentication and again before
    /// calling the service. One emitted start command does not authorize retries.
    func mayStartTransport(_ token: LeaseID) -> Bool {
        lease == token && transport == .starting && state != .terminating
            && startupIssued && !startupIsSettled
    }

    /// A selection is only a permission for future work; it never invalidates
    /// resources already captured by an old GPU submission.
    func mayConsume(_ surface: Surface, generation: MetricSessionID) -> Bool {
        lease == surface.lease && self.generation == generation && selectedSurface == surface
            && state != .terminating && transport == .running
    }

    @discardableResult
    func send(_ event: Event) -> Output {
        var output = Output()
        handle(event, output: &output)
        reconcile(output: &output)
        return output
    }

    private func handle(_ event: Event, output: inout Output) {
        switch event {
        case .start(let serviceIsQuiescent):
            guard lease == nil, state == .idle || state == .terminated,
                  slot == nil, presence == .absent else { output.rejection = .busy; return }
            guard serviceIsQuiescent else { output.rejection = .notReady; return }
            lease = LeaseID()
            state = .starting
            transport = .reserved
            reason = nil
            startupIssued = false
            startupIsSettled = true
            transportIsSettled = true
            abortOpening = false
            requestWindow(output: &output)
            armDeadline(.initialWindow, output: &output)

        case .windowMounted(let surface):
            guard surface == window, surface.lease == lease, state != .terminating else {
                output.rejection = .stale; return
            }
            guard !windowIsMounted else { return }
            windowIsMounted = true
            if state == .starting {
                cancelDeadline(output: &output)
                state = .windowed
                transport = .starting
                startupIssued = true
                startupIsSettled = false
                transportIsSettled = false
                select(surface, output: &output)
                output.effects.append(.startTransport(surface.lease))
            }

        case .transportRunning(let token, let generation):
            guard lease == token, state == .windowed, transport == .starting,
                  self.generation == nil, startupIssued else { output.rejection = .stale; return }
            self.generation = generation
            transport = .running

        case .startupSettled(let token):
            guard lease == token, startupIssued else { output.rejection = .stale; return }
            startupIsSettled = true

        case .transportStopped(let token):
            guard lease == token, state == .terminating else { output.rejection = .stale; return }
            transportIsSettled = true
            transport = .ended

        case .enterImmersion(let token):
            guard lease == token else { output.rejection = .stale; return }
            if state == .immersive { return }
            guard state == .windowed || state == .error else { output.rejection = .busy; return }
            guard transport == .running, windowIsReady, windowIsMounted,
                  window != nil, slot == nil, presence == .absent else {
                output.rejection = .notReady; return
            }
            reason = nil
            abortOpening = false
            immersiveIsReady = false
            let operation = Operation(lease: token)
            let surface = Surface(lease: token, kind: .immersive)
            slot = Slot(operation: operation, awaited: .open)
            immersiveSurface = surface
            state = .opening
            output.effects.append(.openImmersion(operation, surface))

        case .returnToWindow(let token):
            guard lease == token else { output.rejection = .stale; return }
            switch state {
            case .opening: abortOpening = true
            case .immersive: beginRecovery(output: &output)
            case .windowed, .error: break
            default: output.rejection = .busy
            }

        case .consumerReady(let surface, let generation):
            guard surface.lease == lease, self.generation == generation,
                  state != .terminating, transport == .running else {
                output.rejection = .stale; return
            }
            if surface == window, windowIsMounted {
                windowIsReady = true
            } else if surface == immersiveSurface, state == .opening, !abortOpening {
                immersiveIsReady = true
            } else { output.rejection = .stale }

        case .openCompleted(let operation, let result):
            guard operation == slot?.operation, operation.lease == lease,
                  slot?.awaited == .open else { output.rejection = .stale; return }
            slot?.awaited = nil
            switch result {
            case .opened: presence = .open
            case .unknown:
                presence = .unknown
                abortOpening = true
                if state != .terminating { reason = .unknownOpenResult }
            case .userCancelled, .error:
                presence = .absent
                immersiveSurface = nil
                immersiveIsReady = false
                slot = nil
                if state != .terminating {
                    if result == .error, reason == nil { reason = .openFailed }
                    if windowIsReady { finishFallback(showError: reason != nil, output: &output) }
                    else { beginRecovery(output: &output) }
                }
            }

        case .dismissCompleted(let operation):
            guard operation == slot?.operation, operation.lease == lease,
                  slot?.awaited == .dismiss else { output.rejection = .stale; return }
            slot = nil
            presence = .absent
            immersiveSurface = nil
            immersiveIsReady = false
            if state != .terminating {
                if windowIsReady { finishFallback(showError: reason != nil, output: &output) }
                else { beginRecovery(output: &output) }
            }

        case .surfaceDetached(let surface):
            guard surface.lease == lease else { output.rejection = .stale; return }
            if surface == retirement?.surface {
                retirement = nil
            } else if surface == window {
                window = nil
                windowIsMounted = false
                windowIsReady = false
                beginTermination(.windowLost, output: &output)
            } else if surface == immersiveSurface {
                immersiveIsReady = false
                if selectedSurface == surface { select(nil, output: &output) }
                if state == .opening {
                    abortOpening = true
                    reason = .readinessFailed
                } else if state == .immersive {
                    beginRecovery(output: &output)
                }
                // Consumer loss never confirms OS absence. Retain the slot and
                // presence until the outstanding open/dismiss actually resolves.
            } else { output.rejection = .stale }

        case .readinessFailed(let surface):
            guard surface.lease == lease, state != .terminating else {
                output.rejection = .stale; return
            }
            if surface == immersiveSurface, state == .opening {
                immersiveIsReady = false
                abortOpening = true
                reason = .readinessFailed
            } else if surface == immersiveSurface, state == .immersive {
                immersiveIsReady = false
                reason = .readinessFailed
                select(nil, output: &output)
                beginRecovery(output: &output)
            } else if surface == window {
                windowIsReady = false
                if selectedSurface == surface { select(nil, output: &output) }
                if state == .closing || state == .recoveringWindow {
                    reason = .readinessFailed
                } else { beginTermination(.readinessFailed, output: &output) }
            } else { output.rejection = .stale }

        case .terminate(let token, let reason):
            guard lease == token else { output.rejection = .stale; return }
            beginTermination(reason, output: &output)

        case .appPhase(.background):
            if lease != nil { beginTermination(.background, output: &output) }
        case .appPhase, .scenePhase:
            break

        case .deadlineExpired(let token):
            guard token == deadline, token.lease == lease else { output.rejection = .stale; return }
            guard let time = readTime() else {
                beginTermination(.clockUnavailable, output: &output)
                return
            }
            guard time >= token.due else {
                // An early one-shot callback must not strand the transition.
                // Re-arm the same absolute deadline; never extend the budget.
                output.effects.append(.scheduleDeadline(token))
                return
            }
            cancelDeadline(output: &output)
            switch token.kind {
            case .initialWindow, .fallbackWindow:
                beginTermination(.windowTimeout, output: &output)
            case .immersiveReady:
                abortOpening = true
                reason = .readinessFailed
            }
        }
    }

    private func reconcile(output: inout Output) {
        guard let lease else { return }
        switch state {
        case .terminating:
            if slot?.awaited == nil, presence != .absent { dismiss(output: &output) }
            if startupIsSettled, transportIsSettled, slot?.awaited == nil, presence == .absent {
                let outcome = reason ?? .user
                self.lease = nil
                generation = nil
                slot = nil
                window = nil
                immersiveSurface = nil
                retirement = nil
                windowIsMounted = false
                windowIsReady = false
                immersiveIsReady = false
                transport = .ended
                state = .terminated
                output.effects.append(.sessionEnded(lease, outcome))
            }

        case .opening:
            guard slot?.awaited == nil else { return }
            if abortOpening {
                cancelDeadline(output: &output)
                if presence != .absent { dismiss(output: &output) }
            } else if presence == .open, immersiveIsReady, windowIsReady,
                      let surface = immersiveSurface, let window, let operation = slot?.operation {
                cancelDeadline(output: &output)
                select(surface, output: &output)
                let permit = Retirement(operation: operation, surface: window)
                retirement = permit
                self.window = nil
                windowIsMounted = false
                windowIsReady = false
                slot = nil
                state = .immersive
                output.effects.append(.retireWindow(permit))
            } else if presence == .open, deadline == nil {
                armDeadline(.immersiveReady, output: &output)
                // A broken injected clock can request termination while arming.
                if state == .terminating { reconcile(output: &output) }
            }

        case .recoveringWindow:
            if retirement == nil, window == nil { requestWindow(output: &output) }
            guard windowIsReady, windowIsMounted else { return }
            select(window, output: &output)
            cancelDeadline(output: &output)
            if presence != .absent { dismiss(output: &output) }
            else { finishFallback(showError: reason != nil, output: &output) }

        default: break
        }
    }

    private func requestWindow(output: inout Output) {
        guard let lease, retirement == nil else { return }
        if window == nil {
            window = Surface(lease: lease, kind: .window)
            windowIsMounted = false
            windowIsReady = false
        }
        if let window { output.effects.append(.requestWindow(window)) }
    }

    private func beginRecovery(output: inout Output) {
        guard let lease else { return }
        state = .recoveringWindow
        slot = Slot(operation: Operation(lease: lease), awaited: nil)
        armDeadline(.fallbackWindow, output: &output)
        if state != .terminating { requestWindow(output: &output) }
    }

    private func finishFallback(showError: Bool, output: inout Output) {
        cancelDeadline(output: &output)
        slot = nil
        abortOpening = false
        state = showError ? .error : .windowed
        select(window, output: &output)
    }

    private func dismiss(output: inout Output) {
        guard let lease, slot?.awaited == nil, presence != .absent else { return }
        if slot == nil { slot = Slot(operation: Operation(lease: lease), awaited: nil) }
        slot?.awaited = .dismiss
        if state != .terminating { state = .closing }
        if let operation = slot?.operation { output.effects.append(.dismissImmersion(operation)) }
    }

    private func beginTermination(_ reason: Reason, output: inout Output) {
        guard let lease, state != .terminating else { return }
        self.reason = reason
        state = .terminating
        abortOpening = true
        cancelDeadline(output: &output)
        select(nil, output: &output)
        if startupIssued {
            if !startupIsSettled { output.effects.append(.cancelStartup(lease)) }
            transport = .stopping
            output.effects.append(.stopTransport(lease))
        }
    }

    private func select(_ surface: Surface?, output: inout Output) {
        guard selectedSurface != surface else { return }
        let previous = selectedSurface
        selectedSurface = surface
        output.effects.append(.selectConsumer(from: previous, to: surface))
    }

    private func readTime() -> TimeInterval? {
        let time = now()
        guard time.isFinite, time >= lastTime else { return nil }
        lastTime = time
        return time
    }

    private func armDeadline(_ kind: DeadlineKind, output: inout Output) {
        cancelDeadline(output: &output)
        guard let lease else { return }
        guard let time = readTime(), (time + 10).isFinite, time + 10 > time else {
            beginTermination(.clockUnavailable, output: &output)
            return
        }
        let token = Deadline(lease: lease, kind: kind, due: time + 10)
        deadline = token
        output.effects.append(.scheduleDeadline(token))
    }

    private func cancelDeadline(output: inout Output) {
        if let deadline { output.effects.append(.cancelDeadline(deadline)) }
        deadline = nil
    }
}
