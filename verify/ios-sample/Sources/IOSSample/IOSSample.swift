import IOSSampleCxx

public enum IOSSample {
    /// True when the static-linked E57 plugin registrar fired and
    /// `pdal::StageFactory::createStage("readers.e57")` returns a stage.
    public static func e57ReaderRegistered() -> Bool {
        verify_e57_reader_registered() != 0
    }

    /// True when a core in-tree reader (LasReader) is registered.
    /// Useful as a sanity check independent of the E57 plugin shim:
    /// if this is false, PDAL's static-init system isn't running at
    /// all (likely a linker drop, fix with `-Wl,-force_load`).
    public static func lasReaderRegistered() -> Bool {
        verify_las_reader_registered() != 0
    }
}
