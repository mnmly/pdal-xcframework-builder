import XCTest
@testable import IOSSample

final class IOSSampleTests: XCTestCase {

    // Sanity check that PDAL's static-init plugin registry runs at all
    // on iOS. LasReader is a core in-tree reader registered via
    // CREATE_STATIC_STAGE — exactly the same mechanism the E57 plugin
    // uses via our shim. If this fails the rest is moot.
    func testLasReaderRegistered() {
        XCTAssertTrue(
            IOSSample.lasReaderRegistered(),
            "PDAL's static-init plugin registry isn't running on iOS. "
            + "Consumer side likely needs `-Wl,-force_load,<pdalcpp framework path>`."
        )
    }

    // The actual question this verify harness exists to answer: did
    // the out-of-tree plugin compile + scripts/plugin_static_shim.hpp
    // succeed in routing the E57 reader's registration through the
    // static-init path?
    func testE57ReaderRegistered() {
        XCTAssertTrue(
            IOSSample.e57ReaderRegistered(),
            "E57 reader is missing from the plugin registry. "
            + "Check that build.sh build_ios_slice's out-of-tree compile "
            + "ran and the .o files were merged into the framework binary."
        )
    }
}
