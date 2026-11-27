import Photos
import XCTest
@testable import iPhone_Sync

final class PhotoLibrarySourceTests: XCTestCase {
    func testAdjustmentPlistIsIgnored() {
        XCTAssertTrue(PhotoLibrarySource.ignoresSyncResource(
            type: .photo,
            originalFilename: "adjustment.plist"
        ))
        XCTAssertTrue(PhotoLibrarySource.ignoresSyncResource(
            type: .photo,
            originalFilename: "Adjustments/Adjustment.plist"
        ))
        XCTAssertTrue(PhotoLibrarySource.ignoresSyncResource(
            type: .adjustmentData,
            originalFilename: "IMG_0001.HEIC"
        ))
    }

    func testMediaResourcesAreStillSynced() {
        XCTAssertFalse(PhotoLibrarySource.ignoresSyncResource(
            type: .photo,
            originalFilename: "IMG_0001.HEIC"
        ))
        XCTAssertFalse(PhotoLibrarySource.ignoresSyncResource(
            type: .adjustmentBasePhoto,
            originalFilename: "IMG_0001.HEIC"
        ))
        XCTAssertFalse(PhotoLibrarySource.ignoresSyncResource(
            type: .fullSizePhoto,
            originalFilename: "FullSizeRender.jpg"
        ))
        XCTAssertFalse(PhotoLibrarySource.ignoresSyncResource(
            type: .pairedVideo,
            originalFilename: "IMG_0001.MOV"
        ))
    }
}
