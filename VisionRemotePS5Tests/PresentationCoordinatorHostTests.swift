import Foundation

typealias Coordinator = PresentationCoordinator

@MainActor
private enum Checks {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        count += 1
        guard condition() else { fatalError(message, file: file, line: line) }
    }
}

private extension Coordinator.Effect {
    var kind: String {
        switch self {
        case .requestWindow: "requestWindow"
        case .startTransport: "startTransport"
        case .cancelStartup: "cancelStartup"
        case .stopTransport: "stopTransport"
        case .openImmersion: "openImmersion"
        case .dismissImmersion: "dismissImmersion"
        case .selectConsumer: "selectConsumer"
        case .retireWindow: "retireWindow"
        case .scheduleDeadline: "scheduleDeadline"
        case .cancelDeadline: "cancelDeadline"
        case .sessionEnded: "sessionEnded"
        }
    }
}

@MainActor
private final class Fixture {
    var clock: TimeInterval = 100
    lazy var coordinator = Coordinator(now: { [unowned self] in self.clock })
    var effects: [Coordinator.Effect] = []

    @discardableResult
    func send(_ event: Coordinator.Event) -> Coordinator.Output {
        let output = coordinator.send(event)
        effects += output.effects
        return output
    }

    func count(_ kind: String) -> Int { effects.filter { $0.kind == kind }.count }

    func only<T>(_ output: Coordinator.Output, _ select: (Coordinator.Effect) -> T?, _ message: String) -> T {
        let values = output.effects.compactMap(select)
        Checks.expect(values.count == 1, message)
        return values[0]
    }

    func reserve() -> (Coordinator.LeaseID, Coordinator.Surface) {
        let result = send(.start(serviceIsQuiescent: true))
        Checks.expect(result.rejection == nil && coordinator.state == .starting, "A quiescent start reserves one lease")
        guard let lease = coordinator.lease else { fatalError("Reserved start has an owner") }
        let window = only(result, { if case .requestWindow(let value) = $0 { value } else { nil } }, "Start requests exactly one initial window")
        Checks.expect(window.lease == lease && window.kind == .window && coordinator.window == window,
                      "Initial window belongs to the reserved lease")
        Checks.expect(!coordinator.mayStartTransport(lease), "Reservation alone does not authorize authentication or service startup")
        return (lease, window)
    }

    func connected(settleStartup: Bool = true) -> (Coordinator.LeaseID, Coordinator.Surface, MetricSessionID) {
        let (lease, window) = reserve()
        let mounted = send(.windowMounted(window))
        Checks.expect(mounted.effects.contains(.startTransport(lease)), "Mount grants exactly one startup without requiring G")
        Checks.expect(coordinator.mayStartTransport(lease), "The startup driver can check its issued lease")
        let generation = StreamingMetricsRecorder().beginSession()
        send(.transportRunning(lease, generation))
        if settleStartup { send(.startupSettled(lease)) }
        send(.consumerReady(window, generation))
        Checks.expect(coordinator.state == .windowed && coordinator.transport == .running
            && coordinator.generation == generation && coordinator.selectedSurface == window,
                      "Current running transport and ready window bind S/G without reconnecting")
        Checks.expect(coordinator.mayConsume(window, generation: generation), "Selected window can consume the current generation")
        return (lease, window, generation)
    }

    func open(_ lease: Coordinator.LeaseID) -> (Coordinator.Operation, Coordinator.Surface) {
        let output = send(.enterImmersion(lease))
        let command = only(output, { effect -> (Coordinator.Operation, Coordinator.Surface)? in
            if case .openImmersion(let operation, let surface) = effect { return (operation, surface) }
            return nil
        }, "Enter issues one serialized open")
        Checks.expect(output.rejection == nil && coordinator.state == .opening
            && coordinator.pendingOperation == command.0 && coordinator.immersiveSurface == command.1,
                      "Opening retains its operation and candidate surface")
        return command
    }

    func immerse(_ lease: Coordinator.LeaseID, _ generation: MetricSessionID,
                 readyFirst: Bool = false) -> (Coordinator.Operation, Coordinator.Surface) {
        let (operation, surface) = open(lease)
        if readyFirst {
            send(.consumerReady(surface, generation))
            Checks.expect(coordinator.state == .opening && !coordinator.mayConsume(surface, generation: generation),
                          "Readiness before opened cannot grant incoming video permission")
            send(.openCompleted(operation, .opened))
        } else {
            send(.openCompleted(operation, .opened))
            Checks.expect(coordinator.state == .opening && !coordinator.mayConsume(surface, generation: generation),
                          "Opened before readiness does not mean a usable consumer or first frame")
            send(.consumerReady(surface, generation))
        }
        Checks.expect(coordinator.state == .immersive && coordinator.selectedSurface == surface
            && coordinator.mayConsume(surface, generation: generation), "Both acknowledgements transfer exactly one consumer")
        return (operation, surface)
    }

    func finishTransport(_ lease: Coordinator.LeaseID) {
        send(.startupSettled(lease))
        send(.transportStopped(lease))
    }
}

@main
private struct PresentationCoordinatorHostTests {
    @MainActor
    static func main() {
        startAndStartup()
        readinessOrderAndBusyRequests()
        openingOutcomes()
        terminationBarriers()
        settledStartupAndOpenedStop()
        retirementAndRecovery()
        readinessFailureWhileClosing()
        deadlinesAndStaleEvents()
        visibilityAndLoss()
        repeatedCycles()
        print("PASS: \(Checks.count) presentation coordinator assertions; no SwiftUI, transport or device actions executed")
    }

    @MainActor
    static func startAndStartup() {
        let unavailable = Fixture()
        let refused = unavailable.send(.start(serviceIsQuiescent: false))
        Checks.expect(refused.rejection != nil && refused.effects.isEmpty && unavailable.coordinator.lease == nil,
                      "Nonquiescent service cannot reserve another session")
        let f = Fixture()
        let (lease, window) = f.reserve()
        let originalDeadline = f.coordinator.deadline
        let duplicate = f.send(.start(serviceIsQuiescent: true))
        Checks.expect(duplicate.rejection == .busy && f.count("requestWindow") == 1
            && f.coordinator.lease == lease && f.coordinator.deadline == originalDeadline,
                      "Duplicate start does not replace the reservation or renew its deadline")
        f.send(.windowMounted(window))
        f.send(.windowMounted(window))
        Checks.expect(f.count("startTransport") == 1 && f.coordinator.mayStartTransport(lease), "Duplicate mount cannot start twice")
        Checks.expect(f.send(.enterImmersion(lease)).rejection == .notReady, "An authenticated-looking window does not prove transport ready")
        f.send(.terminate(lease, .user))
        Checks.expect(f.coordinator.state == .terminating && !f.coordinator.mayStartTransport(lease), "Stop revokes startup while its await is pending")
        let staleGeneration = StreamingMetricsRecorder().beginSession()
        f.send(.transportRunning(lease, staleGeneration))
        f.send(.windowMounted(window))
        f.send(.terminate(lease, .user))
        Checks.expect(f.coordinator.state == .terminating && f.coordinator.selectedSurface == nil
            && f.count("startTransport") == 1 && f.count("cancelStartup") == 1 && f.count("stopTransport") == 1,
                      "Late startup/duplicate stop cannot reactivate transport or duplicate teardown")
        f.send(.transportStopped(lease))
        Checks.expect(f.coordinator.lease == lease && f.coordinator.state == .terminating, "Native stop does not settle the outstanding startup task")
        f.send(.startupSettled(lease))
        Checks.expect(f.coordinator.state == .terminated && f.coordinator.lease == nil && f.count("sessionEnded") == 1,
                      "Startup plus actual teardown release the lease once")
        f.send(.transportStopped(lease))
        f.send(.startupSettled(lease))
        Checks.expect(f.count("sessionEnded") == 1, "Duplicate acknowledgements cannot end another session")
        print("PASS: reservation, duplicate mount/start and stop during unfinished startup")
    }

    @MainActor
    static func readinessOrderAndBusyRequests() {
        for readyFirst in [false, true] {
            let f = Fixture()
            let (lease, window, generation) = f.connected()
            let (operation, incoming) = f.open(lease)
            let otherGeneration = StreamingMetricsRecorder().beginSession()
            Checks.expect(f.send(.consumerReady(incoming, otherGeneration)).rejection == .stale,
                          "Wrong-generation consumer readiness is rejected")
            Checks.expect(f.send(.enterImmersion(lease)).rejection == .busy, "Another open is not queued")
            Checks.expect(f.send(.start(serviceIsQuiescent: true)).rejection == .busy, "Opening keeps its session reservation")
            if readyFirst {
                f.send(.consumerReady(incoming, generation))
                Checks.expect(f.coordinator.selectedSurface == window, "Window remains selected until open finishes")
                f.send(.openCompleted(operation, .opened))
            } else {
                f.send(.openCompleted(operation, .opened))
                Checks.expect(f.coordinator.selectedSurface == window, "Opened does not transfer before consumer readiness")
                f.send(.consumerReady(incoming, generation))
            }
            Checks.expect(f.coordinator.state == .immersive && f.coordinator.lease == lease
                && f.coordinator.generation == generation && f.coordinator.pendingOperation == nil,
                          "Either ordering produces the same session and settled handoff")
            Checks.expect(!f.coordinator.mayConsume(window, generation: generation)
                && f.coordinator.mayConsume(incoming, generation: generation), "Outgoing permission is revoked before incoming is usable")
            Checks.expect(f.effects.contains(.selectConsumer(from: window, to: incoming)) && f.count("retireWindow") == 1,
                          "Handoff names both concrete surfaces and issues one retirement permit")
            let selections = f.count("selectConsumer")
            f.send(.consumerReady(incoming, generation))
            f.send(.openCompleted(operation, .opened))
            f.send(.enterImmersion(lease))
            Checks.expect(f.count("selectConsumer") == selections && f.count("openImmersion") == 1
                && f.count("startTransport") == 1 && f.count("stopTransport") == 0, "Duplicate ready/result/open does not hand off or reconnect again")
        }
        print("PASS: ready/opened order, busy requests, one generation and exclusive consumer permissions")
    }

    @MainActor
    static func openingOutcomes() {
        for result: Coordinator.OpenResult in [.userCancelled, .error, .unknown] {
            for stopped in [false, true] {
                let f = Fixture()
                let (lease, window, generation) = f.connected()
                let (operation, incoming) = f.open(lease)
                if stopped { f.send(.terminate(lease, .user)); f.finishTransport(lease) }
                let resolved = f.send(.openCompleted(operation, result))
                if result == .unknown {
                    let dismiss = f.only(resolved, { if case .dismissImmersion(let value) = $0 { value } else { nil } },
                                         "Unknown OS result must conservatively drain a serialized dismissal")
                    Checks.expect(dismiss == operation, "Compensating dismissal keeps the opening slot identity")
                    Checks.expect(f.coordinator.pendingOperation == operation, "Unknown result cannot declare OS space absent")
                    f.send(.dismissCompleted(dismiss))
                } else {
                    Checks.expect(f.count("dismissImmersion") == 0, "Known cancelled/error opening did not open an OS space")
                }
                Checks.expect(f.coordinator.state == (stopped ? .terminated : result == .userCancelled ? .windowed : .error),
                              "Opening outcome has a bounded recovery/termination destination")
                if !stopped {
                    Checks.expect(f.coordinator.selectedSurface == window && f.coordinator.mayConsume(window, generation: generation)
                        && f.count("stopTransport") == 0, "Recoverable opening failure preserves window and running transport")
                }
                let effectCount = f.effects.count
                f.send(.consumerReady(incoming, generation))
                f.send(.openCompleted(operation, result))
                Checks.expect(f.effects.count == effectCount, "Late candidate readiness/result after resolution cannot replay the attempt")
            }
        }
        for openedFirst in [false, true] {
            let f = Fixture()
            let (lease, window, generation) = f.connected()
            let (operation, incoming) = f.open(lease)
            if openedFirst { f.send(.openCompleted(operation, .opened)) }
            f.send(.returnToWindow(lease))
            if !openedFirst {
                Checks.expect(f.coordinator.state == .opening && f.coordinator.pendingOperation == operation
                    && f.count("dismissImmersion") == 0, "Cancellation latches intent without releasing an awaited open")
                f.send(.consumerReady(incoming, generation))
                f.send(.openCompleted(operation, .opened))
            }
            Checks.expect(f.coordinator.state == .closing && f.count("dismissImmersion") == 1
                && f.coordinator.selectedSurface == window, "Aborted opened candidate is dismissed without ever selecting it")
            Checks.expect(f.send(.enterImmersion(lease)).rejection == .busy, "A compensating dismiss must finish before a new open")
            Checks.expect(f.send(.returnToWindow(lease)).rejection == .busy, "Busy return is not queued")
            f.send(.dismissCompleted(operation))
            Checks.expect(f.coordinator.state == .windowed && f.count("stopTransport") == 0, "Cancellation restores the current window")
        }
        let failedReady = Fixture()
        let (lease, _, _) = failedReady.connected()
        let (operation, incoming) = failedReady.open(lease)
        failedReady.send(.readinessFailed(incoming))
        Checks.expect(failedReady.coordinator.pendingOperation == operation, "Readiness failure cannot cancel an outstanding OS open by assumption")
        failedReady.send(.openCompleted(operation, .userCancelled))
        Checks.expect(failedReady.coordinator.state == .error && failedReady.coordinator.reason == .readinessFailed,
                      "A subsequent userCancelled result does not erase an earlier readiness failure")
        print("PASS: cancellation/error/unknown outcomes, late results and serialized compensation")
    }

    @MainActor
    static func terminationBarriers() {
        for osFirst in [false, true] {
            for startupFirst in [false, true] {
                let f = Fixture()
                let (lease, _, generation) = f.connected(settleStartup: false)
                let (operation, incoming) = f.open(lease)
                f.send(.terminate(lease, .user))
                Checks.expect(!f.coordinator.mayConsume(incoming, generation: generation), "Termination revokes all consumer permissions")
                if osFirst {
                    f.send(.openCompleted(operation, .opened))
                    f.send(.surfaceDetached(incoming))
                    Checks.expect(f.coordinator.state == .terminating && f.coordinator.pendingOperation == operation,
                                  "Surface disappearance cannot settle outstanding OS dismissal")
                    f.send(.dismissCompleted(operation))
                    Checks.expect(f.coordinator.lease == lease, "OS completion cannot release unsettled startup/transport")
                }
                if startupFirst {
                    f.send(.startupSettled(lease))
                    Checks.expect(f.coordinator.lease == lease, "Startup completion alone cannot release transport")
                    f.send(.transportStopped(lease))
                } else {
                    f.send(.transportStopped(lease))
                    Checks.expect(f.coordinator.lease == lease, "Transport completion alone cannot release startup")
                    f.send(.startupSettled(lease))
                }
                if !osFirst {
                    Checks.expect(f.coordinator.state == .terminating && f.coordinator.lease == lease, "Settled transport cannot discard outstanding open")
                    Checks.expect(f.send(.start(serviceIsQuiescent: true)).rejection == .busy, "Reconnect is blocked by old OS operation ownership")
                    f.send(.openCompleted(operation, .opened))
                    Checks.expect(f.coordinator.state == .terminating && f.count("dismissImmersion") == 1,
                                  "Late opened after stop is drained, never promoted to immersive")
                    f.send(.dismissCompleted(operation))
                }
                Checks.expect(f.coordinator.state == .terminated && f.coordinator.lease == nil
                    && f.coordinator.pendingOperation == nil && f.count("stopTransport") == 1
                    && f.count("cancelStartup") == 1 && f.count("sessionEnded") == 1,
                              "All barrier orderings terminate exactly once")
                let (replacement, replacementWindow) = f.reserve()
                Checks.expect(replacement != lease && replacementWindow.lease == replacement, "Reconnect reserves a fresh lease")
                let effects = f.effects.count
                for event: Coordinator.Event in [.dismissCompleted(operation), .openCompleted(operation, .opened),
                                                .transportRunning(lease, generation), .transportStopped(lease),
                                                .surfaceDetached(incoming)] {
                    f.send(event)
                }
                Checks.expect(f.coordinator.lease == replacement && f.coordinator.window == replacementWindow
                    && f.effects.count == effects, "Old cleanup cannot mutate, stop or dismiss a newly reserved session")
            }
        }
        print("PASS: startup/transport/OS barriers in both orders and late callbacks after reconnect")
    }

    @MainActor
    static func retirementAndRecovery() {
        let f = Fixture()
        let (lease, firstWindow, generation) = f.connected()
        let (_, incoming) = f.immerse(lease, generation)
        guard let permit = f.coordinator.retirement else { fatalError("Handoff must retain a retirement permit") }
        Checks.expect(permit.surface == firstWindow && permit.operation.lease == lease, "Retirement is scoped to exact lease/operation/window")
        let requestedWindows = f.count("requestWindow")
        f.send(.returnToWindow(lease))
        Checks.expect(f.coordinator.state == .recoveringWindow && f.coordinator.selectedSurface == incoming
            && f.count("requestWindow") == requestedWindows && f.count("dismissImmersion") == 0,
                      "Return waits for W1 retirement; it cannot reuse W1 or prematurely dismiss I")
        f.send(.consumerReady(firstWindow, generation))
        Checks.expect(f.coordinator.selectedSurface == incoming, "Late readiness cannot revive a retiring W1")
        let detached = f.send(.surfaceDetached(firstWindow))
        let secondWindow = f.only(detached, { if case .requestWindow(let value) = $0 { value } else { nil } },
                                  "Once W1 detaches, request exactly one distinct fallback W2")
        Checks.expect(secondWindow != firstWindow && secondWindow.lease == lease && f.coordinator.retirement == nil,
                      "Consumed W1 permit cannot exempt a new window from termination behavior")
        f.send(.surfaceDetached(firstWindow))
        Checks.expect(f.coordinator.state == .recoveringWindow && f.coordinator.window == secondWindow,
                      "Late W1 detach cannot remove W2")
        f.send(.windowMounted(secondWindow))
        Checks.expect(f.count("startTransport") == 1 && f.coordinator.selectedSurface == incoming,
                      "Fallback mount neither restarts transport nor substitutes for G readiness")
        let ready = f.send(.consumerReady(secondWindow, generation))
        let dismissal = f.only(ready, { if case .dismissImmersion(let value) = $0 { value } else { nil } },
                                "A ready W2 permits one closing action")
        Checks.expect(f.coordinator.state == .closing && f.coordinator.selectedSurface == secondWindow
            && !f.coordinator.mayConsume(incoming, generation: generation)
            && f.coordinator.mayConsume(secondWindow, generation: generation), "Returning handoff selects only W2 before dismissing I")
        f.send(.dismissCompleted(dismissal))
        Checks.expect(f.coordinator.state == .windowed && f.count("stopTransport") == 0, "Window retirement and return preserve transport")
        f.send(.surfaceDetached(firstWindow))
        f.send(.surfaceDetached(incoming))
        f.send(.surfaceDetached(secondWindow))
        Checks.expect(f.coordinator.state == .terminating && f.count("stopTransport") == 1,
                      "Actual W2 loss without its own permit terminates the session")
        print("PASS: exact retirement permit, delayed W1 detachment, distinct W2 and required-window loss")
    }

    @MainActor
    static func deadlinesAndStaleEvents() {
        let initial = Fixture()
        let (lease, _) = initial.reserve()
        guard let initialDeadline = initial.coordinator.deadline else { fatalError("Initial window has a bounded deadline") }
        Checks.expect(initialDeadline.kind == .initialWindow && initialDeadline.due == 110 && initialDeadline.lease == lease,
                      "Deadline uses the injected monotonic clock and ten-second budget")
        initial.clock = initialDeadline.due - 0.001
        let earlyInitial = initial.send(.deadlineExpired(initialDeadline))
        Checks.expect(initial.coordinator.state == .starting && initial.coordinator.deadline == initialDeadline,
                      "Premature timer delivery cannot expire readiness or change the original deadline")
        Checks.expect(earlyInitial.effects == [.scheduleDeadline(initialDeadline)],
                      "Early one-shot callback rearms the same token/due instead of consuming the only timer or renewing the budget")
        initial.clock = initialDeadline.due
        initial.send(.deadlineExpired(initialDeadline))
        Checks.expect([Coordinator.State.terminating, .terminated].contains(initial.coordinator.state)
            && initial.coordinator.reason == .windowTimeout, "Deadline at the boundary fails the missing window")
        initial.finishTransport(lease)
        let (newLease, newWindow) = initial.reserve()
        initial.send(.deadlineExpired(initialDeadline))
        Checks.expect(initial.coordinator.lease == newLease && initial.coordinator.window == newWindow,
                      "A previous session's deadline cannot terminate the next startup")

        let opening = Fixture()
        let (current, _, _) = opening.connected()
        let (operation, _) = opening.open(current)
        Checks.expect(opening.coordinator.deadline == nil, "No invented deadline can bound an unresolved OS open")
        opening.send(.openCompleted(operation, .opened))
        guard let readyDeadline = opening.coordinator.deadline else { fatalError("Opened candidate requires a readiness deadline") }
        Checks.expect(readyDeadline.kind == .immersiveReady && readyDeadline.due == opening.clock + 10,
                      "Immersive readiness budget starts after opened")
        opening.clock = readyDeadline.due - 0.001
        let earlyReady = opening.send(.deadlineExpired(readyDeadline))
        Checks.expect(earlyReady.effects == [.scheduleDeadline(readyDeadline)]
            && opening.coordinator.deadline == readyDeadline && opening.coordinator.state == .opening,
                      "Early immersive readiness callback rearms its existing deadline without cancelling the opening")
        opening.clock = readyDeadline.due
        opening.send(.deadlineExpired(readyDeadline))
        Checks.expect(opening.coordinator.state == .closing && opening.coordinator.pendingOperation == operation
            && opening.count("dismissImmersion") == 1, "Readiness timeout retains responsibility for OS cleanup")
        opening.send(.deadlineExpired(readyDeadline))
        Checks.expect(opening.count("dismissImmersion") == 1, "Duplicate timeout cannot duplicate dismissal")
        opening.send(.dismissCompleted(operation))
        Checks.expect(opening.coordinator.state == .error && opening.count("stopTransport") == 0,
                      "Immersive readiness timeout recovers the retained window")

        let recovery = Fixture()
        let (owner, window, generation) = recovery.connected()
        _ = recovery.immerse(owner, generation)
        recovery.send(.surfaceDetached(window))
        recovery.send(.returnToWindow(owner))
        guard let fallbackDeadline = recovery.coordinator.deadline else { fatalError("Fallback recovery must be bounded") }
        Checks.expect(fallbackDeadline.kind == .fallbackWindow, "Fallback is distinguished from initial/readiness deadlines")
        recovery.clock = fallbackDeadline.due
        recovery.send(.deadlineExpired(fallbackDeadline))
        Checks.expect(recovery.coordinator.state == .terminating && recovery.count("stopTransport") == 1,
                      "Missing fallback cannot leave an orphaned active stream")
        for invalidTime in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            let invalid = Fixture()
            invalid.clock = invalidTime
            invalid.send(.start(serviceIsQuiescent: true))
            Checks.expect(invalid.coordinator.state == .terminated && invalid.coordinator.lease == nil
                && invalid.coordinator.deadline == nil && invalid.coordinator.reason == .clockUnavailable,
                          "Invalid initial clock cannot create an infinite, expired or unrepresentable deadline")
            Checks.expect(invalid.count("startTransport") == 0 && invalid.count("stopTransport") == 0,
                          "Failed reservation clock never fabricates service startup or teardown work")
        }
        let brokenAfterOpen = Fixture()
        let (brokenLease, _, _) = brokenAfterOpen.connected()
        let (brokenOperation, _) = brokenAfterOpen.open(brokenLease)
        brokenAfterOpen.clock = 99
        brokenAfterOpen.send(.openCompleted(brokenOperation, .opened))
        Checks.expect(brokenAfterOpen.coordinator.state == .terminating
            && brokenAfterOpen.coordinator.reason == .clockUnavailable
            && brokenAfterOpen.coordinator.deadline == nil && brokenAfterOpen.count("dismissImmersion") == 1,
                      "Backward clock after actual opening retains and drains the OS space")
        brokenAfterOpen.finishTransport(brokenLease)
        Checks.expect(brokenAfterOpen.coordinator.lease == brokenLease, "Invalid-clock termination still owns its pending dismissal")
        brokenAfterOpen.send(.dismissCompleted(brokenOperation))
        Checks.expect(brokenAfterOpen.coordinator.state == .terminated, "Broken-clock cleanup releases the lease only after dismissal")
        for invalidTime in [Double.nan, 99] {
            let invalidInitialExpiry = Fixture()
            _ = invalidInitialExpiry.reserve()
            guard let token = invalidInitialExpiry.coordinator.deadline else { fatalError("Reserved window has a timer") }
            invalidInitialExpiry.clock = invalidTime
            invalidInitialExpiry.send(.deadlineExpired(token))
            Checks.expect(invalidInitialExpiry.coordinator.state == .terminated
                && invalidInitialExpiry.coordinator.lease == nil && invalidInitialExpiry.coordinator.deadline == nil
                && invalidInitialExpiry.coordinator.reason == .clockUnavailable,
                          "Invalid clock at initial expiry terminates instead of losing its one-shot deadline")
            Checks.expect(invalidInitialExpiry.count("sessionEnded") == 1
                && invalidInitialExpiry.count("startTransport") == 0 && invalidInitialExpiry.count("stopTransport") == 0,
                          "Initial clock failure releases only the unstarted reservation, without fictitious service work")
            invalidInitialExpiry.send(.deadlineExpired(token))
            Checks.expect(invalidInitialExpiry.count("sessionEnded") == 1,
                          "Repeated invalid-clock expiration cannot terminate twice")

            let invalidReadyExpiry = Fixture()
            let (owner, _, _) = invalidReadyExpiry.connected()
            let (pending, candidate) = invalidReadyExpiry.open(owner)
            invalidReadyExpiry.send(.openCompleted(pending, .opened))
            guard let readyToken = invalidReadyExpiry.coordinator.deadline else { fatalError("Opened candidate has a timer") }
            invalidReadyExpiry.clock = invalidTime
            invalidReadyExpiry.send(.deadlineExpired(readyToken))
            Checks.expect(invalidReadyExpiry.coordinator.state == .terminating
                && invalidReadyExpiry.coordinator.reason == .clockUnavailable
                && invalidReadyExpiry.coordinator.pendingOperation == pending && invalidReadyExpiry.coordinator.deadline == nil,
                          "Invalid expiry clock after opened retains the OS cleanup barrier")
            invalidReadyExpiry.send(.deadlineExpired(readyToken))
            invalidReadyExpiry.send(.surfaceDetached(candidate))
            invalidReadyExpiry.finishTransport(owner)
            Checks.expect(invalidReadyExpiry.coordinator.lease == owner
                && invalidReadyExpiry.count("stopTransport") == 1 && invalidReadyExpiry.count("dismissImmersion") == 1,
                          "Neither consumer loss nor duplicate timer nor service stop can settle the pending dismissal")
            invalidReadyExpiry.send(.dismissCompleted(pending))
            Checks.expect(invalidReadyExpiry.coordinator.state == .terminated && invalidReadyExpiry.count("sessionEnded") == 1,
                          "Only actual dismiss completion releases the opened space after invalid-clock expiry")
        }
        print("PASS: injected deadlines, early/duplicate/stale expiration and bounded fallback")
    }

    @MainActor
    static func readinessFailureWhileClosing() {
        let f = Fixture()
        let (lease, oldWindow, generation) = f.connected()
        _ = f.immerse(lease, generation)
        f.send(.surfaceDetached(oldWindow))
        let returning = f.send(.returnToWindow(lease))
        let window = f.only(returning, { if case .requestWindow(let value) = $0 { value } else { nil } },
                            "Return prepares one fallback registration")
        f.send(.windowMounted(window))
        let ready = f.send(.consumerReady(window, generation))
        let dismiss = f.only(ready, { if case .dismissImmersion(let value) = $0 { value } else { nil } },
                             "Ready fallback begins one dismiss")
        f.send(.readinessFailed(window))
        Checks.expect(f.coordinator.state == .closing && f.coordinator.selectedSurface == nil
            && f.coordinator.reason == .readinessFailed && f.coordinator.pendingOperation == dismiss,
                      "Fallback failure during dismissal revokes the consumer and keeps the pending OS operation")
        f.send(.dismissCompleted(dismiss))
        Checks.expect(f.coordinator.state == .recoveringWindow && f.coordinator.window == window
            && f.coordinator.reason == .readinessFailed && f.coordinator.deadline?.kind == .fallbackWindow,
                      "Dismissal with an unready fallback enters bounded recovery while preserving the failure")
        f.send(.windowMounted(window))
        f.send(.consumerReady(window, generation))
        Checks.expect(f.coordinator.state == .error && f.coordinator.reason == .readinessFailed
            && f.coordinator.selectedSurface == window && f.coordinator.mayConsume(window, generation: generation),
                      "Recovered window with OS space absent retains the recoverable error, consistent with direct dismissal recovery")
        Checks.expect(f.coordinator.deadline == nil && f.coordinator.pendingOperation == nil
            && f.count("dismissImmersion") == 1 && f.count("startTransport") == 1 && f.count("stopTransport") == 0,
                      "Restoring readiness after dismissal neither retries immersion nor restarts the session")
        print("PASS: readiness failure during closing remains an error after window recovery")
    }

    @MainActor
    static func settledStartupAndOpenedStop() {
        let f = Fixture()
        let (lease, window) = f.reserve()
        f.send(.windowMounted(window))
        f.send(.startupSettled(lease))
        Checks.expect(!f.coordinator.mayStartTransport(lease), "A settled startup cannot be issued again while awaiting connection")
        let generation = StreamingMetricsRecorder().beginSession()
        f.send(.transportRunning(lease, generation))
        f.send(.consumerReady(window, generation))
        Checks.expect(f.coordinator.state == .windowed && f.coordinator.mayConsume(window, generation: generation),
                      "A connection delegate may arrive after the startup call settled")
        let (operation, incoming) = f.open(lease)
        f.send(.openCompleted(operation, .opened))
        f.send(.terminate(lease, .user))
        Checks.expect(f.coordinator.state == .terminating && f.coordinator.pendingOperation == operation
            && f.count("dismissImmersion") == 1 && f.count("cancelStartup") == 0,
                      "Stop after opened dismisses immediately and does not cancel an already settled startup")
        f.send(.consumerReady(incoming, generation))
        Checks.expect(f.coordinator.selectedSurface == nil && !f.coordinator.mayConsume(incoming, generation: generation),
                      "Late consumer readiness after stop cannot complete a handoff")
        f.send(.transportStopped(lease))
        Checks.expect(f.coordinator.lease == lease, "Transport acknowledgement does not settle the already issued dismiss")
        f.send(.dismissCompleted(operation))
        Checks.expect(f.coordinator.state == .terminated && f.count("sessionEnded") == 1,
                      "A resolved open with missing readiness still has a complete termination path")
        print("PASS: startup settled before connection and stop between opened and readiness")
    }

    @MainActor
    static func visibilityAndLoss() {
        let f = Fixture()
        let (lease, window, generation) = f.connected()
        let (_, incoming) = f.immerse(lease, generation)
        f.send(.surfaceDetached(window))
        for event: Coordinator.Event in [.appPhase(.inactive), .appPhase(.active),
                                        .scenePhase(.inactive), .scenePhase(.background), .scenePhase(.active)] {
            f.send(event)
        }
        Checks.expect(f.coordinator.state == .immersive && f.count("stopTransport") == 0,
                      "Temporary inactivity and an individual scene background preserve session ownership")
        let loss = f.send(.surfaceDetached(incoming))
        let fallback = f.only(loss, { if case .requestWindow(let value) = $0 { value } else { nil } },
                              "Losing the immersive consumer requests window recovery")
        Checks.expect(f.coordinator.state == .recoveringWindow && f.coordinator.selectedSurface == nil,
                      "Lost selected consumer loses new-work permission immediately")
        f.send(.windowMounted(fallback))
        let ready = f.send(.consumerReady(fallback, generation))
        let dismiss = f.only(ready, { if case .dismissImmersion(let value) = $0 { value } else { nil } },
                            "onDisappear alone cannot prove OS space absence; still dismiss serially")
        Checks.expect(f.coordinator.state == .closing && f.coordinator.pendingOperation == dismiss,
                      "Recovery owns its cleanup until the actual dismiss acknowledgement")
        f.send(.appPhase(.background))
        f.send(.appPhase(.background))
        Checks.expect(f.coordinator.state == .terminating && f.count("stopTransport") == 1
            && f.count("dismissImmersion") == 1, "Aggregate background requests teardown without repeating the existing dismiss")
        f.finishTransport(lease)
        Checks.expect(f.coordinator.lease == lease, "Aggregate background still waits for OS cleanup")
        f.send(.dismissCompleted(dismiss))
        Checks.expect(f.coordinator.state == .terminated, "Background termination completes after both barriers")
        f.send(.appPhase(.active))
        Checks.expect(f.coordinator.state == .terminated && f.count("startTransport") == 1,
                      "Resuming does not reconnect implicitly")
        print("PASS: scene/app phase distinction, immersive loss and serialized background cleanup")
    }

    @MainActor
    static func repeatedCycles() {
        let f = Fixture()
        let (lease, initialWindow, generation) = f.connected()
        var window = initialWindow
        for cycle in 0..<64 {
            let (openedOperation, immersive) = f.immerse(lease, generation, readyFirst: cycle.isMultiple(of: 2))
            f.send(.surfaceDetached(window))
            let returning = f.send(.returnToWindow(lease))
            let nextWindow = f.only(returning, { if case .requestWindow(let value) = $0 { value } else { nil } },
                                    "Each return after retirement requests one current fallback")
            f.send(.windowMounted(nextWindow))
            let ready = f.send(.consumerReady(nextWindow, generation))
            let dismiss = f.only(ready, { if case .dismissImmersion(let value) = $0 { value } else { nil } },
                                 "Each cycle has one closing operation")
            f.send(.dismissCompleted(dismiss))
            f.send(.surfaceDetached(immersive))
            f.send(.openCompleted(openedOperation, .opened))
            f.send(.surfaceDetached(window))
            Checks.expect(f.coordinator.state == .windowed && f.coordinator.lease == lease
                && f.coordinator.generation == generation && f.coordinator.selectedSurface == nextWindow,
                          "Repeated transitions keep the same live session/generation and current surface")
            Checks.expect(f.coordinator.pendingOperation == nil && f.coordinator.immersiveSurface == nil
                && f.coordinator.retirement == nil && f.coordinator.deadline == nil,
                          "Every settled cycle clears its transient operation/surface/permit/deadline slots")
            Checks.expect(!f.coordinator.mayConsume(window, generation: generation)
                && !f.coordinator.mayConsume(immersive, generation: generation)
                && f.coordinator.mayConsume(nextWindow, generation: generation), "Old consumers cannot acquire new work after repeated switches")
            window = nextWindow
        }
        Checks.expect(f.count("openImmersion") == 64 && f.count("dismissImmersion") == 64
            && f.count("retireWindow") == 64 && f.count("startTransport") == 1 && f.count("stopTransport") == 0,
                      "Many cycles do not duplicate transport or accumulate outstanding presentation work")
        f.send(.terminate(lease, .user))
        f.finishTransport(lease)
        Checks.expect(f.coordinator.state == .terminated && f.count("sessionEnded") == 1, "Final termination remains singular after many cycles")
        print("PASS: 64 repeated cycles clear bounded transient ownership and preserve one transport")
    }
}
