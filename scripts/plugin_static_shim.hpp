// Force-included via clang's `-include` flag when compiling PDAL plugin
// sources (e.g. plugins/e57/io/*.cpp) for iOS static linking.
//
// PDAL's plugin sources use CREATE_SHARED_STAGE(T, info), which expands
// to an `extern "C" PF_initPlugin()` entry point — the dlopen-style
// registration path used on macOS for loadable .dylib plugins. Static
// archives can't use that path; their globals get dropped at consumer
// link time unless `-force_load` is used.
//
// PDAL ships a sibling macro CREATE_STATIC_STAGE(T, info) that emits a
// static-init `bool T##_b = registerPlugin<T>(info);` — the same path
// PDAL's in-tree readers (LasReader, CopcReader, ...) use to register
// when compiled directly into libpdal_base.a.
//
// We redirect the macro by including PluginHelper.hpp first (so the
// original definitions land), then `#undef` + redefine. The plugin
// source files trigger this on `#include "PluginHelper.hpp"` because
// their copy is guarded by `#pragma once`, so our redefinition wins.
//
// Why not patch PDAL upstream: the project's CLAUDE.md commits to
// being a "pure orchestrator over upstream tags." A 4-line shim used
// only when cross-compiling for iOS keeps that contract intact.

#pragma once

#include <pdal/PluginHelper.hpp>

#undef  CREATE_SHARED_STAGE
#define CREATE_SHARED_STAGE(T, info) CREATE_STATIC_STAGE(T, info)
