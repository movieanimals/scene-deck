import SwiftUI
import HueCore

/// Used only after explicit Bridge connection; the initial demo performs no network access.
/// Events invalidate the snapshot; a trailing refresh catches events arriving during a fetch.
@MainActor final class BridgeSynchronizer: ObservableObject {
    @Published private(set) var snapshot: HomeSnapshot?
    @Published private(set) var status = "Disconnected"
    private var task: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var running = false
    private var lastAttempt: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var unavailable = false
    @Published private(set) var lastUpdated: Date?
    private let pollInterval: TimeInterval
    private let minimumFetchInterval: TimeInterval
    private let eventDebounce: TimeInterval
    private let retryInterval: TimeInterval
    private let foregroundInterval: TimeInterval
    private let now: () -> Date
    private var pendingRefresh: Task<Void, Never>?
    private var dirty = false
    private var generation = 0
    private(set) var paused = false
    @Published private(set) var authorizationRequired = false
    private let fetch: () async throws -> [HueResource]
    private let events: (@escaping () async -> Void) async throws -> Void
    private let close: () -> Void
    convenience init(client: HueClient, bridgeID: String = "", host: String = "", addressChanged: @escaping (String) -> Void = { _ in }) {
        if bridgeID.isEmpty || host.isEmpty {
            self.init(fetch: { try await client.resources() }, events: { try await client.listen(onChange: $0) }, close: { client.close() })
        } else {
            let connection = HueReadConnection(client: client, bridgeID: bridgeID, host: host, addressChanged: addressChanged)
            self.init(fetch: { try await connection.resources() }, events: { try await connection.listen(onChange: $0) }, close: { Task { await connection.close() } })
        }
    }
    init(fetch: @escaping () async throws -> [HueResource], events: @escaping (@escaping () async -> Void) async throws -> Void, close: @escaping () -> Void, pollInterval: TimeInterval = 60, minimumFetchInterval: TimeInterval = 1, eventDebounce: TimeInterval = 0.25, retryInterval: TimeInterval = 1, foregroundInterval: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch; self.events = events; self.close = close
        self.pollInterval = pollInterval; self.minimumFetchInterval = minimumFetchInterval; self.eventDebounce = eventDebounce
        self.retryInterval = retryInterval; self.foregroundInterval = foregroundInterval; self.now = now
    }
    /// All read triggers share one queue. Lighting commands are never retried here.
    func start() {
        guard !paused, !authorizationRequired else { return }
        stop(); running = true
        let token = generation, events = events, interval = pollInterval
        enqueueRefresh(debounce: false)
        let initial = pendingRefresh
        task = Task { [weak self] in
            await initial?.value
            var delay: UInt64 = 1
            while !Task.isCancelled, self?.generation == token {
                do {
                    try await events { [weak self] in
                        guard self?.generation == token else { return }
                        self?.enqueueRefresh(debounce: true)
                    }
                } catch is CancellationError { break }
                catch let error as HueError where error.requiresAccessRecovery {
                    if self?.generation == token { self?.revokeAccess() }
                    break
                } catch { }
                guard !Task.isCancelled, self?.generation == token else { break }
                self?.status = "Live updates interrupted. Reconnecting…"
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                guard !Task.isCancelled, self?.generation == token else { break }
                self?.enqueueRefresh(debounce: false)
                await self?.pendingRefresh?.value
                delay = min(delay * 2, 30)
            }
        }
        if interval > 0 {
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(interval)) } catch { break }
                    guard self?.generation == token else { break }
                    self?.reconcileIfStale()
                }
            }
        }
    }
    func refresh() { enqueueRefresh(debounce: false) }
    func refreshOnForeground() {
        guard lastUpdated.map({ now().timeIntervalSince($0) >= foregroundInterval }) ?? true else { return }
        enqueueRefresh(debounce: false)
    }
    private func reconcileIfStale() {
        guard lastUpdated.map({ now().timeIntervalSince($0) >= pollInterval }) ?? true else { return }
        enqueueRefresh(debounce: false)
    }
    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
    private func enqueueRefresh(debounce: Bool) {
        guard running, !paused, !authorizationRequired else { return }
        dirty = true
        guard pendingRefresh == nil else { return }
        let token = generation, fetch = fetch, now = now, minimum = minimumFetchInterval, retry = retryInterval
        let debounceDelay = debounce ? eventDebounce : 0
        refreshing = true
        pendingRefresh = Task { [weak self] in
            var retryDelay = retry
            do {
                if debounceDelay > 0 { try await Task.sleep(nanoseconds: Self.nanoseconds(debounceDelay)) }
                repeat {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    if let previous = self?.lastAttempt {
                        let remaining = minimum - now().timeIntervalSince(previous)
                        if remaining > 0 { try await Task.sleep(nanoseconds: Self.nanoseconds(remaining)) }
                    }
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.dirty = false; self?.refreshing = true; self?.lastAttempt = now()
                    do {
                        let resources = try await fetch()
                        guard !Task.isCancelled, self?.generation == token else { return }
                        self?.snapshot = HomeSnapshot.project(resources)
                        self?.lastUpdated = now(); self?.unavailable = false
                        self?.status = "Up to date"; retryDelay = retry
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as HueError where error.requiresAccessRecovery {
                        if self?.generation == token { self?.revokeAccess() }; return
                    } catch {
                        guard !Task.isCancelled, self?.generation == token else { return }
                        self?.unavailable = true; self?.refreshing = false
                        self?.status = "Bridge unavailable. Keeping the last scenes; retrying…"
                        try await Task.sleep(nanoseconds: Self.nanoseconds(retryDelay))
                        retryDelay = min(retryDelay * 2, 30)
                        self?.dirty = true
                    }
                } while self?.dirty == true
            } catch { /* Cancellation preserves the last known snapshot. */ }
            if self?.generation == token { self?.pendingRefresh = nil; self?.refreshing = false }
        }
    }
    private func revokeAccess() {
        stop(); close(); authorizationRequired = true; unavailable = true
        status = "Bridge access needs attention. Choose Reconnect to check saved access."
    }
    func pauseForSleep() { stop(); close(); paused = true; status = "Mac sleeping. Reconnecting automatically after wake." }
    func stop() {
        generation += 1; running = false
        task?.cancel(); task = nil
        pendingRefresh?.cancel(); pendingRefresh = nil
        pollingTask?.cancel(); pollingTask = nil
        dirty = false; refreshing = false; status = "Disconnected"
    }
    deinit { task?.cancel(); pendingRefresh?.cancel(); pollingTask?.cancel(); close() }
}
