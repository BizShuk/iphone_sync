@preconcurrency import Photos
import Foundation
import Observation
import SyncCore

@MainActor
@Observable
final class IOSAppModel {
    enum State: Equatable {
        case setup
        case ready
        case findingMac
        case pairing
        case syncing
        case error(String)
    }

    var state: State = .setup
    var authorizationStatus: PHAuthorizationStatus
    var albums: [PhotoAlbum] = []
    var selectedAlbums: [PhotoAlbum] = []
    var pairedPeer: PairedPeer?
    var receivers: [DiscoveredReceiver] = []
    var pairingCode = ""
    var pairingError: String?
    var pairingExpiresAt: Date?
    var pairingIsPending = false
    var progress: IOSSyncProgress?
    var lastSummary: SyncSummary?

    @ObservationIgnored private let photoSource = PhotoLibrarySource()
    @ObservationIgnored private let albumStore = AlbumSelectionStore()
    @ObservationIgnored private var coordinator: IOSSyncCoordinator!
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    init() {
        authorizationStatus = photoSource.authorizationStatus()
        let defaults = UserDefaults.standard
        let deviceID: String
        if let existing = defaults.string(forKey: "deviceID") {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        coordinator = IOSSyncCoordinator(
            photoSource: photoSource,
            deviceID: deviceID,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            }
        )
    }

    var hasFullPhotoAccess: Bool {
        authorizationStatus == .authorized
    }

    var canSync: Bool {
        hasFullPhotoAccess
            && !selectedAlbums.isEmpty
            && pairedPeer != nil
            && state != .syncing
    }

    var selectedAlbumsText: String {
        switch selectedAlbums.count {
        case 0: "Not selected"
        case 1: selectedAlbums[0].title
        default: "\(selectedAlbums.count) selected"
        }
    }

    func bootstrap() async {
        do {
            pairedPeer = try await coordinator.loadPairedPeer()
            if hasFullPhotoAccess {
                try loadAlbums()
            }
            state = hasFullPhotoAccess && !selectedAlbums.isEmpty && pairedPeer != nil
                ? .ready
                : .setup
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func requestPhotosAccess() {
        Task {
            authorizationStatus = await photoSource.requestFullAccess()
            guard authorizationStatus == .authorized else {
                state = .error(PhotoLibrarySourceError.fullAccessRequired.localizedDescription)
                return
            }
            do {
                try loadAlbums()
                state = selectedAlbums.isEmpty || pairedPeer == nil ? .setup : .ready
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func selectAlbums(_ albums: [PhotoAlbum]) {
        selectedAlbums = albums
        albumStore.save(albums)
        state = albums.isEmpty || pairedPeer == nil ? .setup : .ready
    }

    func findMac() {
        discoveryTask?.cancel()
        state = .findingMac
        receivers = []
        discoveryTask = Task {
            let stream = await coordinator.receiverStream(pairing: pairedPeer == nil)
            for await values in stream {
                guard !Task.isCancelled else { break }
                receivers = values
            }
        }
    }

    func beginPairing(with receiver: DiscoveredReceiver) {
        discoveryTask?.cancel()
        Task {
            do {
                try await coordinator.beginPairing(receiver: receiver)
                pairingCode = ""
                pairingError = nil
                pairingExpiresAt = Date().addingTimeInterval(120)
                pairingIsPending = true
                state = .pairing
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func confirmPairing() {
        guard pairingCode.count == 6,
              pairingCode.allSatisfy({ $0.isNumber }) else { return }
        Task {
            do {
                pairedPeer = try await coordinator.confirmPairing(code: pairingCode)
                pairingIsPending = false
                pairingError = nil
                pairingExpiresAt = nil
                state = selectedAlbums.isEmpty ? .setup : .ready
            } catch let error as PairingClientError {
                pairingError = error.localizedDescription
                if case let .codeMismatch(remainingAttempts) = error,
                   remainingAttempts > 0 {
                    state = .pairing
                } else {
                    pairingIsPending = false
                    pairingExpiresAt = nil
                    state = .error(error.localizedDescription)
                }
            } catch {
                pairingIsPending = false
                pairingExpiresAt = nil
                state = .error(error.localizedDescription)
            }
        }
    }

    func cancelPairing() {
        pairingIsPending = false
        pairingCode = ""
        pairingError = nil
        pairingExpiresAt = nil
        state = selectedAlbums.isEmpty || pairedPeer == nil ? .setup : .ready
        Task { await coordinator.cancelPairing() }
    }

    func syncNow() {
        guard !selectedAlbums.isEmpty else { return }
        let albums = selectedAlbums
        state = .syncing
        Task {
            do {
                lastSummary = try await coordinator.sync(albums: albums)
                pairedPeer = try await coordinator.loadPairedPeer()
                state = .ready
            } catch is CancellationError {
                state = .ready
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        Task {
            await coordinator.cancel()
        }
    }

    func forgetMac() {
        Task {
            do {
                try await coordinator.forgetPeer()
                pairedPeer = nil
                state = .setup
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func enteredBackground() {
        switch state {
        case .syncing:
            cancel()
        case .pairing:
            cancelPairing()
        default:
            break
        }
    }

    private func loadAlbums() throws {
        albums = try photoSource.albums()
        let savedIDs = Set(albumStore.load().map(\.id))
        selectedAlbums = albums.filter { savedIDs.contains($0.id) }
        if selectedAlbums.isEmpty {
            albumStore.clear()
        } else {
            albumStore.save(selectedAlbums)
        }
    }
}
