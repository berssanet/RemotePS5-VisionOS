import Foundation

private typealias C = PresentationCoordinator
private typealias D = PresentationSessionDriver

@MainActor
private enum Verify {
    static var count = 0
    static func that(_ condition: @autoclosure () -> Bool, _ message: String,
                     file: StaticString = #file, line: UInt = #line) {
        count += 1
        guard condition() else { fatalError(message, file: file, line: line) }
    }
    static func until(_ message: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<3_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Async fixture did not settle: " + message)
    }
    static func drain() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class DriverFixture {
    struct Timer {
        let id = UUID()
        let due: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    enum Failure: Error { case authentication, timer }
    var clock: TimeInterval = 100
    var quiescent = true
    var suspendAuthentication = true
    var failAuthentication = false
    var supplyImmersiveAdapters = true
    var starts: [C.LeaseID] = []
    var nativeStarts: [C.LeaseID] = []
    var deniedAfterAuthentication: [C.LeaseID] = []
    var mayStartChecks: [C.LeaseID: @MainActor () -> Bool] = [:]
    var callbacks: [C.LeaseID: @MainActor @Sendable (D.TransportEvent) -> Void] = [:]
    var authWaiters: [C.LeaseID: CheckedContinuation<Void, Never>] = [:]
    var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var stopRequests = 0
    var stopWaitCalls = 0
    var prepareCalls = 0
    var endDeliveryCalls = 0
    var openedWindows: [C.Surface] = []
    var closedWindows: [C.Surface] = []
    var openCalls: [(C.Operation, C.Surface)] = []
    var dismissCalls: [C.Operation] = []
    var openWaiters: [C.Operation: CheckedContinuation<C.OpenResult, Never>] = [:]
    var dismissWaiters: [C.Operation: CheckedContinuation<Void, Never>] = [:]
    var status: [(C.LeaseID, D.TransportEvent)] = []
    var ended: [(C.LeaseID, C.Reason)] = []
    var updates = 0
    var timers: [Timer] = []
    var selectedConsumer: C.Surface?
    var consumerSelections: [C.Surface?] = []
    var selectionAtWindowClose: [C.Surface?] = []
    var selectionAtDismiss: [C.Surface?] = []
    var selectionAtStop: [C.Surface?] = []
    var onSelectConsumer: (@MainActor (C.Surface?) -> Void)?
    var onPrepareDelivery: (@MainActor () -> Void)?
    var onEndDelivery: (@MainActor () -> Void)?
    lazy var coordinator = C(now: { [unowned self] in self.clock })
    lazy var driver = D(coordinator: coordinator, environment: environment())

    private func environment() -> D.Environment {
        var value = D.Environment(serviceIsQuiescent: { [unowned self] in self.quiescent },
            start: { [unowned self] lease, mayStart, event in
                self.starts.append(lease)
                self.mayStartChecks[lease] = mayStart
                self.callbacks[lease] = event
                event(.connecting)
                if self.suspendAuthentication {
                    // Intentionally ignores Task cancellation until the test
                    // releases AUTH: permission must be checked after the await.
                    await withCheckedContinuation { self.authWaiters[lease] = $0 }
                }
                if self.failAuthentication { throw Failure.authentication }
                guard mayStart() else { self.deniedAfterAuthentication.append(lease); return }
                self.nativeStarts.append(lease)
                self.quiescent = false
                event(.negotiating)
                event(.running(StreamingMetricsRecorder().beginSession()))
            }, requestStop: { [unowned self] in
                self.stopRequests += 1
                self.selectionAtStop.append(self.selectedConsumer)
            },
            waitForStop: { [unowned self] in
                self.stopWaitCalls += 1
                await withCheckedContinuation { self.stopWaiters.append($0) }
                self.quiescent = true
            }, prepareDelivery: { [unowned self] in
                self.prepareCalls += 1
                self.onPrepareDelivery?()
            }, endDelivery: { [unowned self] in
                self.endDeliveryCalls += 1
                self.onEndDelivery?()
            },
            openWindow: { [unowned self] in self.openedWindows.append($0) },
            closeWindow: { [unowned self] in
                self.closedWindows.append($0)
                self.selectionAtWindowClose.append(self.selectedConsumer)
            },
            transportStatus: { [unowned self] in self.status.append(($0, $1)) },
            didEnd: { [unowned self] in self.ended.append(($0, $1)) },
            didUpdate: { [unowned self] in self.updates += 1 },
            selectConsumer: { [unowned self] surface in
                self.selectedConsumer = surface
                self.consumerSelections.append(surface)
                self.onSelectConsumer?(surface)
            })
        if supplyImmersiveAdapters {
            value.openImmersion = { [unowned self] operation, surface in
                self.openCalls.append((operation, surface))
                return await withCheckedContinuation { self.openWaiters[operation] = $0 }
            }
            value.dismissImmersion = { [unowned self] operation in
                self.dismissCalls.append(operation)
                self.selectionAtDismiss.append(self.selectedConsumer)
                await withCheckedContinuation { self.dismissWaiters[operation] = $0 }
            }
        }
        value.sleepUntil = { [unowned self] due in
            // Also intentionally survives cancellation until delivered. This
            // models an adapter with an already-dispatched stale timer callback.
            try await withCheckedThrowingContinuation {
                self.timers.append(Timer(due: due, continuation: $0))
            }
        }
        return value
    }

    func releaseAuthentication(_ lease: C.LeaseID) {
        guard let continuation = authWaiters.removeValue(forKey: lease) else { fatalError("Missing AUTH continuation") }
        continuation.resume()
    }
    func releaseStop() {
        Verify.that(stopWaiters.count == 1, "One service stop waiter owns actual teardown")
        stopWaiters.removeFirst().resume()
    }
    func releaseOpen(_ operation: C.Operation, _ result: C.OpenResult) {
        guard let continuation = openWaiters.removeValue(forKey: operation) else { fatalError("Missing OS open continuation") }
        continuation.resume(returning: result)
    }
    func releaseDismiss(_ operation: C.Operation) {
        guard let continuation = dismissWaiters.removeValue(forKey: operation) else { fatalError("Missing OS dismiss continuation") }
        continuation.resume()
    }
    func fireTimer(_ id: UUID, at time: TimeInterval) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { fatalError("Missing fake timer") }
        clock = time
        timers.remove(at: index).continuation.resume()
    }

    func reserve() -> (C.LeaseID, C.Surface) {
        let result = driver.startSession()
        Verify.that(result.rejection == nil && driver.isBusy && openedWindows.count >= 1,
                    "Start reserves ownership and asks the window adapter once")
        guard let lease = driver.activeLease, let surface = coordinator.window else { fatalError("Missing reserved identity") }
        Verify.that(driver.ownsWindow(surface) && surface.lease == lease, "Only the issued concrete registration belongs to the driver")
        return (lease, surface)
    }

    func connect() async -> (C.LeaseID, C.Surface, MetricSessionID) {
        let (lease, window) = reserve()
        driver.consumerPrepared(window)
        driver.windowMounted(window)
        await Verify.until("AUTH begins") { self.authWaiters[lease] != nil }
        releaseAuthentication(lease)
        await Verify.until("transport running and prepared consumer replayed") {
            self.coordinator.transport == .running && self.coordinator.generation != nil
                && self.coordinator.selectedSurface == window && self.authWaiters.isEmpty
        }
        await Verify.drain()
        guard let generation = coordinator.generation else { fatalError("No G from current service acknowledgement") }
        Verify.that(coordinator.mayConsume(window, generation: generation), "Prepared-before-G window receives the current generation")
        return (lease, window, generation)
    }

    func immerse(_ lease: C.LeaseID, _ generation: MetricSessionID) async -> (C.Operation, C.Surface) {
        driver.send(.enterImmersion(lease))
        await Verify.until("OS open entered") { !self.openWaiters.isEmpty }
        guard let operation = coordinator.pendingOperation, let surface = coordinator.immersiveSurface else { fatalError("Missing opening identities") }
        driver.consumerPrepared(surface)
        Verify.that(!coordinator.mayConsume(surface, generation: generation), "Prepared candidate cannot consume before actual open result")
        releaseOpen(operation, .opened)
        await Verify.until("immersive consumer selected") { self.coordinator.state == .immersive }
        return (operation, surface)
    }

    func finish() async {
        driver.terminate()
        // Settle all deliberately suspended adapter calls, including cancelled
        // timers, so the harness never abandons checked continuations.
        for _ in 0..<12 {
            let authentication = Array(authWaiters.values)
            authWaiters.removeAll()
            authentication.forEach { $0.resume() }
            let opening = Array(openWaiters.values)
            openWaiters.removeAll()
            opening.forEach { $0.resume(returning: .userCancelled) }
            let dismissing = Array(dismissWaiters.values)
            dismissWaiters.removeAll()
            dismissing.forEach { $0.resume() }
            let stopping = stopWaiters
            stopWaiters.removeAll()
            stopping.forEach { $0.resume() }
            let pendingTimers = timers
            timers.removeAll()
            pendingTimers.forEach { $0.continuation.resume(throwing: CancellationError()) }
            await Verify.drain()
        }
        Verify.that(!driver.isBusy && authWaiters.isEmpty && stopWaiters.isEmpty
            && openWaiters.isEmpty && dismissWaiters.isEmpty && timers.isEmpty,
                    "Fixture cleanup settles owned startup/transport/OS work and all fake timers")
    }
}

@main
private struct PresentationSessionDriverHostTests {
    @MainActor
    static func main() async throws {
        await authenticationAndStopBarrier()
        await invalidatedBeforeTaskAndReentrantCleanup()
        await duplicateAndRestoredWindow()
        await lateEventsAfterReconnect()
        await retirementAndWindowRecovery()
        await selectionReentrancyAndAppPhase()
        await repeatedCyclesWithoutImmersiveDisappear()
        await openedAfterStop()
        await deadlinesAndCancelledTimers()
        await immediateClockFailureAndUnexpectedSleeperError()
        await failedStartupAndMissingAdapter()
        try await opaqueCodableSurface()
        print("PASS: \(Verify.count) session driver assertions with suspended fake adapters; no device or real timers")
    }

    @MainActor
    static func authenticationAndStopBarrier() async {
        let f = DriverFixture()
        let (lease, window) = f.reserve()
        f.driver.windowMounted(window)
        f.driver.consumerPrepared(window)
        await Verify.until("start suspended in AUTH") { f.authWaiters[lease] != nil }
        Verify.that(f.starts == [lease] && f.nativeStarts.isEmpty && f.mayStartChecks[lease]?() == true,
                    "AUTH has one issued startup lease and has not acquired native resources")
        f.driver.terminate()
        Verify.that(f.selectedConsumer == nil && f.consumerSelections == [window, nil]
            && f.selectionAtStop == [nil],
                    "Consumer admission is revoked synchronously before service stop, including suspended AUTH")
        Verify.that(f.stopRequests == 1 && f.driver.isBusy && f.driver.activeLease == lease,
                    "Stop request is synchronous but does not falsely acknowledge teardown")
        Verify.that(f.mayStartChecks[lease]?() == false && !f.driver.isCurrent(lease),
                    "Termination revokes permission before a cancelled authentication await returns")
        f.driver.terminate()
        Verify.that(f.driver.startSession().rejection == .busy && f.stopRequests == 1,
                    "Duplicate stop/start cannot replace an unfinished authentication owner")
        let statusBefore = f.status.count
        f.callbacks[lease]?(.running(StreamingMetricsRecorder().beginSession()))
        f.callbacks[lease]?(.failed("late-auth-fixture"))
        Verify.that(f.coordinator.generation == nil && f.status.count == statusBefore,
                    "Late service callbacks during termination cannot restore G or update current UI")
        await Verify.drain()
        Verify.that(f.driver.activeLease == lease && f.ended.isEmpty, "Ignoring cancellation in AUTH does not release the lease early")
        f.releaseAuthentication(lease)
        await Verify.until("actual service stop waiter") { f.stopWaiters.count == 1 }
        Verify.that(f.nativeStarts.isEmpty && f.deniedAfterAuthentication == [lease]
            && f.driver.activeLease == lease && f.ended.isEmpty,
                    "Returned AUTH rechecks permission; startup settled alone is not actual service stop")
        f.releaseStop()
        await Verify.until("both startup/transport barriers") { !f.driver.isBusy }
        Verify.that(f.ended.count == 1 && f.ended[0].0 == lease && f.stopRequests == 1
            && f.stopWaitCalls == 1 && f.endDeliveryCalls == 1,
                    "Actual teardown ends delivery and reports the original lease exactly once")
        await f.finish()
        print("PASS: suspended AUTH, immediate stop request and delayed startup/transport acknowledgements")
    }

    @MainActor
    static func duplicateAndRestoredWindow() async {
        let f = DriverFixture()
        let (lease, window, generation) = await f.connect()
        f.driver.windowMounted(window)
        f.driver.consumerPrepared(window)
        f.driver.windowMounted(window)
        Verify.that(f.driver.startSession().rejection == .busy, "Repeated start cannot acquire a second connection")
        await Verify.drain()
        Verify.that(f.starts == [lease] && f.nativeStarts == [lease] && f.prepareCalls == 1
            && f.coordinator.generation == generation && f.openedWindows == [window],
                    "Repeated view mount/preparation retains one startup, delivery preparation and window")
        let other = DriverFixture()
        let (_, restored) = other.reserve()
        f.driver.windowMounted(restored)
        f.driver.consumerPrepared(restored)
        f.driver.surfaceDetached(restored)
        Verify.that(!f.driver.ownsWindow(restored) && f.coordinator.window == window && f.stopRequests == 0,
                    "An unowned restored registration cannot start or terminate the active session")
        await other.finish()
        f.driver.surfaceDetached(window)
        Verify.that(f.coordinator.state == .terminating && f.stopRequests == 1,
                    "Closing the required window outside a handoff requests termination")
        await f.finish()
        print("PASS: duplicate/restored window registration and required-window closure")
    }

    @MainActor
    static func invalidatedBeforeTaskAndReentrantCleanup() async {
        let skipped = DriverFixture()
        let (lease, window) = skipped.reserve()
        skipped.driver.windowMounted(window)
        // Stay on this actor until termination has invalidated the queued task.
        skipped.driver.terminate()
        Verify.that(skipped.stopRequests == 1 && skipped.driver.activeLease == lease,
                    "Queued startup invalidation still owns one explicit stop acknowledgement")
        await Verify.until("uninvoked startup settles") { skipped.stopWaiters.count == 1 }
        Verify.that(skipped.starts.isEmpty && skipped.prepareCalls == 0 && skipped.nativeStarts.isEmpty,
                    "Startup invalidated before task entry cannot prepare delivery or invoke authentication")
        skipped.releaseStop()
        await Verify.until("uninvoked startup released") { !skipped.driver.isBusy }
        Verify.that(skipped.endDeliveryCalls == 0 && skipped.ended.count == 1,
                    "Cleanup does not disable delivery that this lease never prepared")
        await skipped.finish()

        let reentrant = DriverFixture()
        var attemptedStarts: [C.Output] = []
        reentrant.onPrepareDelivery = { [unowned reentrant] in reentrant.driver.terminate() }
        reentrant.onEndDelivery = { [unowned reentrant] in
            attemptedStarts.append(reentrant.driver.startSession())
        }
        let (owner, registered) = reentrant.reserve()
        reentrant.driver.windowMounted(registered)
        await Verify.until("stop issued synchronously inside prepareDelivery") { reentrant.stopWaiters.count == 1 }
        Verify.that(reentrant.prepareCalls == 1 && reentrant.starts.isEmpty && reentrant.nativeStarts.isEmpty
            && reentrant.driver.activeLease == owner && reentrant.stopRequests == 1,
                    "A reentrant stop inside preparation is revalidated before invoking authentication/service")
        reentrant.releaseStop()
        await Verify.until("reentrant cleanup complete") { !reentrant.driver.isBusy }
        Verify.that(attemptedStarts.count == 1 && attemptedStarts[0].rejection == .busy
            && attemptedStarts[0].effects.isEmpty && reentrant.openedWindows.count == 1,
                    "Old endDelivery finishes while the driver remains busy; it cannot race a new session enable")
        Verify.that(reentrant.endDeliveryCalls == 1 && reentrant.ended.count == 1,
                    "Reentrant preparation/cleanup still ends one delivery lease exactly once")
        reentrant.onPrepareDelivery = nil
        reentrant.onEndDelivery = nil
        await reentrant.finish()
        print("PASS: invalidation before task entry and reentrant delivery preparation/cleanup")
    }

    @MainActor
    static func lateEventsAfterReconnect() async {
        let f = DriverFixture()
        let (oldLease, oldWindow, oldGeneration) = await f.connect()
        let oldCallback = f.callbacks[oldLease]!
        let oldMayStart = f.mayStartChecks[oldLease]!
        await f.finish()
        let (newLease, newWindow, newGeneration) = await f.connect()
        Verify.that(newLease != oldLease && newGeneration != oldGeneration && oldMayStart() == false,
                    "Reconnect receives fresh lease/G while old startup permission remains invalid")
        let priorStatus = f.status.count
        let priorStops = f.stopRequests
        let priorEnds = f.endDeliveryCalls
        let priorSelections = f.consumerSelections
        oldCallback(.connecting)
        oldCallback(.negotiating)
        oldCallback(.running(oldGeneration))
        oldCallback(.failed("old-session-fixture"))
        f.driver.windowMounted(oldWindow)
        f.driver.consumerPrepared(oldWindow)
        f.driver.surfaceDetached(oldWindow)
        f.driver.send(.transportStopped(oldLease))
        await Verify.drain()
        Verify.that(f.driver.activeLease == newLease && f.coordinator.generation == newGeneration
            && f.coordinator.selectedSurface == newWindow && f.status.count == priorStatus
            && f.stopRequests == priorStops && f.endDeliveryCalls == priorEnds,
                    "Callbacks carrying old lease/G/surface cannot mutate UI, transport or delivery for B")
        Verify.that(f.starts.count == 2 && f.nativeStarts.count == 2 && f.driver.ownsWindow(newWindow),
                    "Two explicit sessions result in exactly two starts")
        Verify.that(f.selectedConsumer == newWindow && f.consumerSelections == priorSelections,
                    "Old lease callbacks cannot revoke or replace the new session's consumer gate")
        await f.finish()
        print("PASS: retained callbacks and startup permission remain stale after reconnect")
    }

    @MainActor
    static func retirementAndWindowRecovery() async {
        let f = DriverFixture()
        let (lease, oldWindow, generation) = await f.connect()
        let (_, immersive) = await f.immerse(lease, generation)
        Verify.that(f.consumerSelections == [oldWindow, immersive]
            && f.selectionAtWindowClose == [immersive],
                    "Immersive admission replaces W1 synchronously before the exact window retirement")
        Verify.that(f.closedWindows == [oldWindow] && f.driver.ownsWindow(oldWindow)
            && f.endDeliveryCalls == 0 && f.stopRequests == 0,
                    "Retirement closes the exact outgoing window without global session/delivery termination")
        f.driver.send(.returnToWindow(lease))
        Verify.that(f.coordinator.state == .recoveringWindow && f.openedWindows.count == 1
            && f.coordinator.selectedSurface == immersive && f.dismissCalls.isEmpty,
                    "Return waits for retiring W1 to detach before requesting a distinct W2")
        f.driver.surfaceDetached(oldWindow)
        guard let window = f.coordinator.window else { fatalError("No fallback after exact retirement acknowledgement") }
        Verify.that(window != oldWindow && f.openedWindows == [oldWindow, window]
            && !f.driver.ownsWindow(oldWindow) && f.driver.ownsWindow(window), "W2 is a fresh owned registration")
        f.driver.surfaceDetached(oldWindow)
        f.driver.windowMounted(window)
        f.driver.consumerPrepared(window)
        Verify.that(f.selectedConsumer == window && f.consumerSelections == [oldWindow, immersive, window],
                    "Fallback readiness grants W2 immediately without resetting session delivery or G")
        await Verify.until("return dismiss entered") { !f.dismissWaiters.isEmpty }
        Verify.that(f.selectionAtDismiss == [window], "W2 owns rendering before the ID-less OS dismissal is invoked")
        let dismissal = f.coordinator.pendingOperation!
        Verify.that(f.coordinator.selectedSurface == window && f.coordinator.generation == generation
            && f.prepareCalls == 1 && f.endDeliveryCalls == 0 && f.starts == [lease],
                    "Window handoff preserves G, one native session and global delivery")
        f.driver.surfaceDetached(immersive)
        Verify.that(f.coordinator.state == .closing && f.driver.isBusy, "Immersive disappearance cannot settle an outstanding OS dismiss")
        f.releaseDismiss(dismissal)
        await Verify.until("return complete") { f.coordinator.state == .windowed }
        Verify.that(f.coordinator.mayConsume(window, generation: generation)
            && !f.coordinator.mayConsume(immersive, generation: generation) && f.stopRequests == 0,
                    "Only the current window consumes after the awaited dismissal")
        f.driver.surfaceDetached(window)
        Verify.that(f.stopRequests == 1, "Actual W2 closure outside a retirement permit retains intended termination")
        await f.finish()
        print("PASS: exact retirement, delayed W1 detachment, fresh W2 and preserved delivery/G")
    }

    @MainActor
    static func selectionReentrancyAndAppPhase() async {
        let beforeStart = DriverFixture()
        let (lease, window) = beforeStart.reserve()
        beforeStart.onSelectConsumer = { [unowned beforeStart] surface in
            if surface == window { beforeStart.driver.terminate() }
        }
        beforeStart.driver.windowMounted(window)
        Verify.that(beforeStart.selectedConsumer == nil
            && beforeStart.consumerSelections == [window, nil] && beforeStart.selectionAtStop == [nil],
                    "Reentrant termination during initial selection revokes the gate before the pending start effect")
        await Verify.until("reentrant selection stop waits") { beforeStart.stopWaiters.count == 1 }
        Verify.that(beforeStart.starts.isEmpty && beforeStart.prepareCalls == 0
            && beforeStart.driver.activeLease == lease,
                    "An obsolete start after a reentrant selection cannot acquire resources or free S before teardown")
        beforeStart.releaseStop()
        await Verify.until("reentrant selection stopped") { !beforeStart.driver.isBusy }
        beforeStart.onSelectConsumer = nil
        await beforeStart.finish()

        let handoff = DriverFixture()
        let (handoffLease, oldWindow, generation) = await handoff.connect()
        handoff.driver.send(.enterImmersion(handoffLease))
        await Verify.until("reentrant handoff open waits") { !handoff.openWaiters.isEmpty }
        let operation = handoff.coordinator.pendingOperation!
        let immersive = handoff.coordinator.immersiveSurface!
        handoff.driver.consumerPrepared(immersive)
        Verify.that(handoff.selectedConsumer == oldWindow && handoff.consumerSelections == [oldWindow],
                    "Preparing a candidate without the OS open result never acquires the consumer gate")
        handoff.onSelectConsumer = { [unowned handoff] surface in
            if surface == immersive { handoff.driver.terminate() }
        }
        handoff.releaseOpen(operation, .opened)
        await Verify.until("reentrant handoff dismiss waits") { !handoff.dismissWaiters.isEmpty }
        Verify.that(handoff.selectedConsumer == nil
            && handoff.consumerSelections == [oldWindow, immersive, nil]
            && handoff.selectionAtStop == [nil] && handoff.selectionAtDismiss == [nil],
                    "Reentrant stop during handoff cannot replay an obsolete grant before OS compensation")
        Verify.that(handoff.selectionAtWindowClose == [nil] && handoff.coordinator.generation == generation,
                    "Outgoing window retirement sees the revoked gate and does not replace the generation")
        handoff.onSelectConsumer = nil
        await handoff.finish()

        let phases = DriverFixture()
        let (phaseLease, phaseWindow, phaseGeneration) = await phases.connect()
        let (_, phaseImmersive) = await phases.immerse(phaseLease, phaseGeneration)
        phases.driver.surfaceDetached(phaseWindow)
        phases.driver.send(.scenePhase(.background))
        phases.driver.send(.appPhase(.inactive))
        phases.driver.send(.appPhase(.active))
        Verify.that(phases.driver.isBusy && phases.selectedConsumer == phaseImmersive
            && phases.coordinator.state == .immersive && phases.stopRequests == 0,
                    "Retired window background and app inactive do not terminate the active immersive consumer")
        phases.driver.send(.appPhase(.background))
        Verify.that(phases.selectedConsumer == nil && phases.selectionAtStop == [nil]
            && phases.coordinator.reason == .background,
                    "Actual aggregate app background revokes admission synchronously and owns cleanup")
        await phases.finish()
        print("PASS: synchronous consumer gate transfer, reentrant selection/stop and app versus retired-window phase")
    }

    @MainActor
    static func openedAfterStop() async {
        let f = DriverFixture()
        let (lease, _, _) = await f.connect()
        f.driver.send(.enterImmersion(lease))
        await Verify.until("open suspended") { !f.openWaiters.isEmpty }
        let operation = f.coordinator.pendingOperation!
        let candidate = f.coordinator.immersiveSurface!
        f.driver.terminate()
        let revokedSelections = f.consumerSelections
        Verify.that(f.selectedConsumer == nil && f.selectionAtStop == [nil],
                    "Stop revokes window admission before waiting for a late OS open")
        await Verify.until("transport shutdown suspended") { f.stopWaiters.count == 1 }
        f.releaseStop()
        await Verify.drain()
        Verify.that(f.driver.activeLease == lease && f.driver.startSession().rejection == .busy,
                    "An outstanding OS open retains the session after native stop")
        f.releaseOpen(operation, .opened)
        await Verify.until("compensating dismiss") { f.dismissWaiters[operation] != nil }
        f.driver.consumerPrepared(candidate)
        Verify.that(f.coordinator.state == .terminating && f.coordinator.selectedSurface == nil
            && f.dismissCalls == [operation] && f.openCalls.count == 1,
                    "Late opened after stop triggers one compensation under the same operation")
        Verify.that(f.consumerSelections == revokedSelections && f.selectedConsumer == nil
            && f.selectionAtDismiss == [nil],
                    "Late open/readiness cannot grant the cancelled candidate while compensation drains")
        f.releaseDismiss(operation)
        await Verify.until("old OS action drained") { !f.driver.isBusy }
        Verify.that(f.ended.count == 1 && f.endDeliveryCalls == 1, "Only completed compensation releases the terminated lease")
        await f.finish()
        print("PASS: late OS open after stop remains owned until compensating dismissal")
    }

    @MainActor
    static func repeatedCyclesWithoutImmersiveDisappear() async {
        let f = DriverFixture()
        let (lease, initialWindow, generation) = await f.connect()
        var window = initialWindow
        Verify.that(f.driver.preparedSurfaceCount == 1, "Connected driver retains one prepared window")
        for _ in 0..<32 {
            _ = await f.immerse(lease, generation)
            Verify.that(f.driver.preparedSurfaceCount <= 2, "Opening/handoff retains only current surface registrations")
            f.driver.surfaceDetached(window)
            f.driver.send(.returnToWindow(lease))
            guard let replacement = f.coordinator.window else { fatalError("Missing current fallback registration") }
            Verify.that(replacement != window && f.driver.preparedSurfaceCount <= 2,
                        "Retirement removes old W before preparing the distinct replacement")
            f.driver.windowMounted(replacement)
            f.driver.consumerPrepared(replacement)
            await Verify.until("repeated cycle dismiss started") { !f.dismissWaiters.isEmpty }
            Verify.that(f.driver.preparedSurfaceCount <= 2, "Closing cannot accumulate older immersive registrations")
            let dismissal = f.coordinator.pendingOperation!
            f.releaseDismiss(dismissal)
            await Verify.until("repeated cycle returned") { f.coordinator.state == .windowed }
            // Intentionally omit surfaceDetached(I). The OS completion alone
            // must prune prepared metadata for the no-longer-current surface.
            Verify.that(f.driver.preparedSurfaceCount == 1 && f.coordinator.immersiveSurface == nil
                && f.coordinator.selectedSurface == replacement
                && f.coordinator.mayConsume(replacement, generation: generation),
                        "After dismissal, only ready W remains even if visual onDisappear never arrives")
            window = replacement
        }
        Verify.that(f.starts == [lease] && f.nativeStarts == [lease] && f.prepareCalls == 1
            && f.endDeliveryCalls == 0 && f.openCalls.count == 32 && f.dismissCalls.count == 32,
                    "Thirty-two metadata cleanup cycles preserve one transport/delivery lifetime")
        await f.finish()
        Verify.that(f.driver.preparedSurfaceCount == 0, "Terminated driver retains no prepared surface metadata")
        print("PASS: 32 cycles without immersive onDisappear keep prepared metadata bounded and clear it on termination")
    }

    @MainActor
    static func deadlinesAndCancelledTimers() async {
        let f = DriverFixture()
        let (lease, _) = f.reserve()
        await Verify.until("initial fake timer") { f.timers.count == 1 }
        let first = f.timers[0]
        f.fireTimer(first.id, at: first.due - 0.5)
        await Verify.until("early timer rearmed") { f.timers.count == 1 }
        Verify.that(f.timers[0].due == first.due && f.coordinator.state == .starting,
                    "Early adapter wake rearms the same due time without adding ten seconds")
        f.fireTimer(f.timers[0].id, at: first.due)
        await Verify.until("unmounted window timeout") { !f.driver.isBusy }
        Verify.that(f.ended.count == 1 && f.ended[0].0 == lease && f.ended[0].1 == .windowTimeout
            && f.starts.isEmpty, "Initial deadline releases an unstarted lease with a fixed timeout reason")
        await f.finish()

        let stale = DriverFixture()
        let (_, window) = stale.reserve()
        await Verify.until("timer before mount") { stale.timers.count == 1 }
        let cancelled = stale.timers[0]
        stale.driver.windowMounted(window)
        await Verify.until("AUTH in progress") { !stale.authWaiters.isEmpty }
        stale.fireTimer(cancelled.id, at: cancelled.due + 1)
        await Verify.drain()
        Verify.that(stale.driver.isBusy && stale.coordinator.state == .windowed && stale.stopRequests == 0,
                    "Cancelled timer delivered late cannot expire a mounted window or stop its authentication")
        await stale.finish()
        print("PASS: fake deadline expiration, early rearm and cancellation-resistant late timer")
    }

    @MainActor
    static func failedStartupAndMissingAdapter() async {
        let failed = DriverFixture()
        failed.failAuthentication = true
        let (lease, window) = failed.reserve()
        failed.driver.windowMounted(window)
        await Verify.until("failed AUTH ready") { failed.authWaiters[lease] != nil }
        failed.releaseAuthentication(lease)
        await Verify.until("failure requests actual stop") { failed.stopWaiters.count == 1 }
        Verify.that(failed.coordinator.state == .terminating && failed.driver.activeLease == lease
            && failed.stopRequests == 1 && failed.nativeStarts.isEmpty, "Thrown startup error remains owned until real cleanup")
        failed.releaseStop()
        await Verify.until("failed startup ended") { !failed.driver.isBusy }
        Verify.that(failed.ended.last?.1 == .transportFailure, "Authentication failure is classified as transport failure")
        await failed.finish()

        let unavailable = DriverFixture()
        unavailable.supplyImmersiveAdapters = false
        let (owner, windowReady, generation) = await unavailable.connect()
        unavailable.driver.send(.enterImmersion(owner))
        await Verify.until("missing OS adapter resolves") {
            unavailable.coordinator.state == .error || unavailable.coordinator.state == .windowed
        }
        Verify.that(unavailable.openCalls.isEmpty && unavailable.dismissCalls.isEmpty
            && unavailable.coordinator.pendingOperation == nil && unavailable.coordinator.selectedSurface == windowReady
            && unavailable.coordinator.mayConsume(windowReady, generation: generation) && unavailable.stopRequests == 0,
                    "Window-only driver refuses unavailable immersive work without abandoning an operation or session")
        await unavailable.finish()
        print("PASS: startup failure cleanup and bounded refusal without immersive adapters")
    }

    @MainActor
    static func immediateClockFailureAndUnexpectedSleeperError() async {
        let invalidStart = DriverFixture()
        invalidStart.clock = .nan
        invalidStart.driver.startSession()
        Verify.that(!invalidStart.driver.isBusy && invalidStart.driver.activeLease == nil
            && invalidStart.coordinator.state == .terminated && invalidStart.ended.count == 1
            && invalidStart.ended[0].1 == .clockUnavailable,
                    "A lease reserved and terminated inside one reducer send still reaches didEnd exactly once")
        Verify.that(invalidStart.openedWindows.isEmpty && invalidStart.starts.isEmpty
            && invalidStart.prepareCalls == 0 && invalidStart.stopRequests == 0 && invalidStart.endDeliveryCalls == 0,
                    "Immediate invalid clock executes no stale open, startup or delivery command")
        await invalidStart.finish()
        Verify.that(invalidStart.ended.count == 1, "Cleanup cannot report the already ended invalid-clock lease twice")

        let initialTimer = DriverFixture()
        let (initialLease, _) = initialTimer.reserve()
        await Verify.until("initial deadline awaiting sleeper") { initialTimer.timers.count == 1 }
        initialTimer.timers.removeFirst().continuation.resume(throwing: DriverFixture.Failure.timer)
        await Verify.until("unexpected initial sleeper failure ended") { !initialTimer.driver.isBusy }
        Verify.that(initialTimer.ended.count == 1 && initialTimer.ended[0].0 == initialLease
            && initialTimer.ended[0].1 == .clockUnavailable && initialTimer.coordinator.deadline == nil,
                    "Unexpected current sleeper failure cannot silently consume the sole initial deadline")
        Verify.that(initialTimer.starts.isEmpty && initialTimer.stopRequests == 0,
                    "Failed initial timer does not fabricate startup or native teardown")
        await initialTimer.finish()

        let openedTimer = DriverFixture()
        let (lease, window) = openedTimer.reserve()
        await Verify.until("timer to become stale") { openedTimer.timers.count == 1 }
        let staleTimerID = openedTimer.timers[0].id
        openedTimer.driver.consumerPrepared(window)
        openedTimer.driver.windowMounted(window)
        await Verify.until("opened timer fixture AUTH") { openedTimer.authWaiters[lease] != nil }
        openedTimer.releaseAuthentication(lease)
        await Verify.until("opened timer fixture running") { openedTimer.coordinator.transport == .running }
        await Verify.drain()
        openedTimer.driver.send(.enterImmersion(lease))
        await Verify.until("opening before readiness deadline") { !openedTimer.openWaiters.isEmpty }
        let operation = openedTimer.coordinator.pendingOperation!
        let candidate = openedTimer.coordinator.immersiveSurface!
        openedTimer.releaseOpen(operation, .opened)
        await Verify.until("current immersive readiness timer") {
            openedTimer.coordinator.deadline?.kind == .immersiveReady
                && openedTimer.timers.contains { $0.id != staleTimerID }
        }
        let staleIndex = openedTimer.timers.firstIndex { $0.id == staleTimerID }!
        openedTimer.timers.remove(at: staleIndex).continuation.resume(throwing: DriverFixture.Failure.timer)
        await Verify.drain()
        Verify.that(openedTimer.coordinator.state == .opening && openedTimer.stopRequests == 0
            && openedTimer.coordinator.deadline?.kind == .immersiveReady,
                    "Unexpected failure from an already cancelled old timer cannot affect its replacement")
        Verify.that(openedTimer.timers.count == 1, "Only the current readiness sleeper remains suspended")
        openedTimer.timers.removeFirst().continuation.resume(throwing: DriverFixture.Failure.timer)
        await Verify.until("current sleeper failure starts both cleanup barriers") {
            openedTimer.stopWaiters.count == 1 && openedTimer.dismissWaiters[operation] != nil
        }
        Verify.that(openedTimer.coordinator.state == .terminating
            && openedTimer.coordinator.reason == .clockUnavailable && openedTimer.driver.activeLease == lease,
                    "Current timer failure after opened retains ownership while draining the OS space")
        openedTimer.releaseStop()
        await Verify.until("transport settled before dismiss") { openedTimer.coordinator.transport == .ended }
        openedTimer.driver.surfaceDetached(candidate)
        Verify.that(openedTimer.driver.isBusy && openedTimer.ended.isEmpty
            && openedTimer.dismissCalls == [operation] && openedTimer.stopRequests == 1,
                    "Native teardown and consumer disappearance cannot replace actual dismissal acknowledgement")
        openedTimer.releaseDismiss(operation)
        await Verify.until("unexpected sleeper failure fully settled") { !openedTimer.driver.isBusy }
        Verify.that(openedTimer.ended.count == 1 && openedTimer.ended[0].1 == .clockUnavailable
            && openedTimer.endDeliveryCalls == 1,
                    "Clock failure ends the original delivery exactly once after both barriers")
        await openedTimer.finish()
        print("PASS: same-send clock failure and unexpected current/stale sleeper errors")
    }

    @MainActor
    static func opaqueCodableSurface() async throws {
        let f = DriverFixture()
        let (_, surface) = f.reserve()
        let encoded = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(C.Surface.self, from: encoded)
        Verify.that(decoded == surface && f.driver.ownsWindow(decoded), "Codable scene value preserves the exact opaque registration")
        let dictionary = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let lease = dictionary["lease"] as! [String: Any]
        let kind = dictionary["kind"] as! [String: Any]
        Verify.that(Set(dictionary.keys) == ["lease", "kind", "id"] && Set(lease.keys) == ["value"]
            && Set(kind.keys) == ["window"], "Scene serialization contains only explicit identity/type fields")
        Verify.that(UUID(uuidString: dictionary["id"] as! String) != nil
            && UUID(uuidString: lease["value"] as! String) != nil,
                    "Surface and lease serialize as opaque UUIDs, without console host, account or credential fields")
        await f.finish()
        let restored = DriverFixture()
        restored.driver.windowMounted(decoded)
        restored.driver.consumerPrepared(decoded)
        Verify.that(!restored.driver.isBusy && !restored.driver.ownsWindow(decoded) && restored.starts.isEmpty,
                    "Restored old token alone never authorizes a new runtime session")
        await restored.finish()
        print("PASS: opaque Codable registration allowlist and restored-session refusal")
    }
}
