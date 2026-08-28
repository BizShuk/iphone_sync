import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

final class SyncedResourceLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SyncedResourceLedgerTests.\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    /// The regression this ledger exists for: a second run must recognise a
    /// resource the Mac already confirmed, so it never exports and hashes the
    /// original again just to be told it is already present.
    func testConfirmedResourceIsRecognisedByALaterRun() throws {
        let identity = makeIdentity()
        let descriptor = makeDescriptor(for: identity)

        let firstRun = makeLedger()
        XCTAssertNil(firstRun.confirmedDescriptor(
            for: identity,
            sourceBindingID: "binding-1"
        ))
        firstRun.record(descriptor, for: identity, sourceBindingID: "binding-1")
        firstRun.flush()

        let secondRun = makeLedger()
        XCTAssertEqual(
            secondRun.confirmedDescriptor(
                for: identity,
                sourceBindingID: "binding-1"
            ),
            descriptor
        )
    }

    func testEditedAssetIsNotRecognised() throws {
        let identity = makeIdentity()
        let ledger = makeLedger()
        ledger.record(
            makeDescriptor(for: identity),
            for: identity,
            sourceBindingID: "binding-1"
        )
        ledger.flush()

        let edited = PhotoResourceIdentity(
            assetLocalIdentifier: identity.assetLocalIdentifier,
            assetCreationDate: identity.assetCreationDate,
            assetModificationDate: Date(timeIntervalSince1970: 2_000),
            resourceType: identity.resourceType,
            originalFilename: identity.originalFilename,
            duplicateOrdinal: identity.duplicateOrdinal,
            role: identity.role
        )

        XCTAssertNil(ledger.confirmedDescriptor(
            for: edited,
            sourceBindingID: "binding-1"
        ))
    }

    func testAnotherDestinationBindingIsNotRecognised() throws {
        let identity = makeIdentity()
        let ledger = makeLedger()
        ledger.record(
            makeDescriptor(for: identity),
            for: identity,
            sourceBindingID: "binding-1"
        )
        ledger.flush()

        XCTAssertNil(ledger.confirmedDescriptor(
            for: identity,
            sourceBindingID: "binding-2"
        ))
    }

    func testForgetDropsTheRecordForLaterRunsToo() throws {
        let identity = makeIdentity()
        let ledger = makeLedger()
        ledger.record(
            makeDescriptor(for: identity),
            for: identity,
            sourceBindingID: "binding-1"
        )
        ledger.forget(identity, sourceBindingID: "binding-1")
        ledger.flush()

        XCTAssertNil(makeLedger().confirmedDescriptor(
            for: identity,
            sourceBindingID: "binding-1"
        ))
    }

    func testClearRemovesEveryRecord() throws {
        let identity = makeIdentity()
        let ledger = makeLedger()
        ledger.record(
            makeDescriptor(for: identity),
            for: identity,
            sourceBindingID: "binding-1"
        )
        ledger.clear()
        ledger.flush()

        XCTAssertNil(makeLedger().confirmedDescriptor(
            for: identity,
            sourceBindingID: "binding-1"
        ))
    }

    private func makeLedger() -> SyncedResourceLedger {
        SyncedResourceLedger(
            fileURL: directory.appendingPathComponent("synced-resources.jsonl")
        )
    }

    private func makeIdentity() -> PhotoResourceIdentity {
        PhotoResourceIdentity(
            assetLocalIdentifier: "asset-1",
            assetCreationDate: Date(timeIntervalSince1970: 500),
            assetModificationDate: Date(timeIntervalSince1970: 1_000),
            resourceType: "photo",
            originalFilename: "IMG_0001.HEIC",
            duplicateOrdinal: 0,
            role: "primary"
        )
    }

    private func makeDescriptor(
        for identity: PhotoResourceIdentity
    ) -> ResourceDescriptor {
        ResourceDescriptor(
            assetLocalIdentifier: identity.assetLocalIdentifier,
            resourceType: identity.resourceType,
            originalFilename: identity.originalFilename,
            duplicateOrdinal: identity.duplicateOrdinal,
            contentHash: String(repeating: "a", count: 64),
            expectedSize: 2_048,
            creationDate: identity.assetCreationDate,
            role: identity.role
        )
    }
}
