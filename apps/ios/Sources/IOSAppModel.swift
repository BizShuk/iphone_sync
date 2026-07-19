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
    var selectedAlbum: PhotoAlbum?
    var pairedPeer: PairedPeer?
    var receivers: [DiscoveredReceiver] = []
    var pairingCode = ""
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
            && selectedAlbum != nil
            && pairedPeer != nil
            && state != .syncing
    }

    func bootstrap() async {
        do {
            pairedPeer = try await coordinator.loadPairedPeer()
            if hasFullPhotoAccess {
                try loadAlbums()
            }
            state = hasFullPhotoAccess && selectedAlbum != nil && pairedPeer != nil
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
                state = .setup
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func selectAlbum(_ album: PhotoAlbum) {
        selectedAlbum = album
        albumStore.save(album)
        state = pairedPeer == nil ? .setup : .ready
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
                state = selectedAlbum == nil ? .setup : .ready
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func syncNow() {
        guard let selectedAlbum else { return }
        state = .syncing
        Task {
            do {
                lastSummary = try await coordinator.sync(album: selectedAlbum)
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
            state = .ready
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
        guard state == .syncing else { return }
        cancel()
    }

    private func loadAlbums() throws {
        albums = try photoSource.albums()
        if let saved = albumStore.load(),
           let current = albums.first(where: { $0.id == saved.id }) {
            selectedAlbum = current
        } else {
            selectedAlbum = nil
            albumStore.clear()
        }
    }
}
