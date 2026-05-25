// pdal_static_anchors.cpp
//
// Anchor file for PDAL's file-scope static plugin registrars on iOS.
//
// PDAL registers each Reader/Writer/Filter via `CREATE_STATIC_STAGE`
// (see PluginHelper.hpp), which expands to a TU-internal
// `static bool T_b = registerPlugin<T>(info);`. When pdalcpp ships as
// a static archive (iOS slices), `ld64` strips any `.o` whose
// external symbols are unreferenced — so the registrar runs only if
// some external symbol from the same TU is referenced from outside
// the archive.
//
// Most stages whose headers SwiftPDAL exposes can be anchored
// downstream by just `new`-ing them. The exception is plugin-tree
// stages (e.g. `pdal::E57Reader`), whose headers live under PDAL's
// `plugins/<name>/io/` and are not part of PDAL's public include set.
// Downstream consumers therefore can't `#include` them without
// vendoring the plugin source tree.
//
// This file is compiled by `pdal-xcframework-builder` from inside the
// PDAL build tree, where every plugin header is reachable via a
// short relative include path. It exposes one `extern "C"` symbol —
// `pdal_ensure_static_plugins()` — that downstream consumers call
// once. Calling it (a) references this TU, which the linker pulls
// into the final image, and (b) references each anchored stage's
// vtable/ctor via `new T()`, dragging that stage's `.o` out of the
// merged archive.
//
// Add new in-builder static plugins here as PDAL grows them. Stages
// whose headers PDAL already exposes under `pdal/io/` or
// `pdal/filters/` do NOT need entries here — downstream consumers
// anchor those themselves.

#include "E57Reader.hpp"

namespace {

template <class T>
void anchor(volatile void** sink) {
    T* p = new T();
    *sink = static_cast<void*>(p);
    delete p;
}

} // namespace

extern "C" void pdal_ensure_static_plugins() {
    volatile void* sink = nullptr;

    anchor<pdal::E57Reader>(&sink);

    (void)sink;
}
