import SwiftUI
import HueCore

/// Used only after explicit Bridge connection; the initial demo performs no network access.
/// Events invalidate the snapshot; a trailing refresh catches events arriving during a fetch.
@MainActor final class BridgeSynchronizer: ObservableObject {
    @Published private(set) var snapshot: HomeSnapshot?
    @Published private(set) var status = "Disconnected"
    private var task: Task<Void, Never>?
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
    init(fetch: @escaping () async throws -> [HueResource], events: @escaping (@escaping () async -> Void) async throws -> Void, close: @escaping () -> Void) {
        self.fetch = fetch; self.events = events; self.close = close
    }
    func start() {
        guard !paused, !authorizationRequired else { return }
        stop()
        let token = generation
        let fetch = fetch, events = events
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    let resources = try await fetch()
                    guard !Task.isCancelled, self?.generation == token else { break }
                    self?.snapshot = HomeSnapshot.project(resources)
                    self?.status = "Live"
                    try await events { [weak self] in
                        guard self?.generation == token else { return }
                        self?.scheduleRefresh()
                    }
                } catch is CancellationError { break }
                catch HueError.http(let code) where code == 401 || code == 403 {
                    guard self?.generation == token else { break }
                    self?.revokeAccess()
                    break
                }
                catch { }
                guard !Task.isCancelled, self?.generation == token else { break }
                self?.status = "Connection interrupted. Retrying…"
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                delay = min(delay * 2, 30)
            }
        }
    }
    private func scheduleRefresh() {
        dirty = true
        guard pendingRefresh == nil else { return }
        let token = generation, fetch = fetch
        pendingRefresh = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                repeat {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.dirty = false
                    let resources = try await fetch()
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.snapshot = HomeSnapshot.project(resources)
                    self?.status = "Live"
                } while self?.dirty == true
            } catch HueError.http(let code) where code == 401 || code == 403 {
                if !Task.isCancelled, self?.generation == token { self?.revokeAccess() }
            } catch {
                if !Task.isCancelled, self?.generation == token { self?.status = "Refresh failed. Reconnect to try again." }
            }
            if self?.generation == token { self?.pendingRefresh = nil }
        }
    }
    private func revokeAccess() {
        stop(); close(); authorizationRequired = true
        status = "Bridge access was revoked. Reconnect explicitly to recover."
    }
    func pauseForSleep() { stop(); close(); paused = true; status = "Paused after sleep. Choose Reconnect when ready." }
    func stop() {
        generation += 1
        task?.cancel(); task = nil
        pendingRefresh?.cancel(); pendingRefresh = nil
        dirty = false; status = "Disconnected"
    }
    deinit { task?.cancel(); pendingRefresh?.cancel(); close() }
}
