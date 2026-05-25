# lazperf patches (applied to PDAL's vendored copy)

PDAL vendors a copy of `hobuinc/laz-perf` at `src/vendor/lazperf/` inside
its source tree. SwiftPDAL's `copclib.xcframework` separately bundles
upstream `hobuinc/laz-perf@master` plus a local patch that adds a
`reset(InputCb)` virtual on `lazperf::las_decompressor` (a new vtable
slot). When both archives end up linked into a single iOS consumer
binary, their `las_decompressor` vtables disagree and virtual dispatch
from copclib code lands on the wrong slot — manifesting as
`__cxa_pure_virtual` from `point_decompressor_0::decompress`.

The patch here mirrors the **API surface** of
`SwiftPDAL/Frameworks/lazperf-patches/0001-add-reset-api.patch` — same
new symbols, same vtable layout. It diverges in exactly two context
lines because PDAL vendors an older lazperf snapshot than upstream
master:

- `vendor/lazperf/lazperf.cpp` constructor body uses
  `p_(new Private(cb, ebCount))` (PDAL) vs
  `p_(new Private(std::move(cb), ebCount))` (upstream).
- `vendor/lazperf/streams.hpp` `InCbStream` ctor uses
  `inCb_(inCb)` (PDAL) vs `inCb_(std::move(inCb))` (upstream).

Only the context lines differ; the `+` lines (the new API) are
identical to the SwiftPDAL copy. **The resulting ABI is the same.**

When refreshing this patch (e.g. PDAL bumps its vendored snapshot
forward), re-derive from SwiftPDAL's copy and adjust the two context
lines if needed.

## How it's applied

`build.sh` phase 1.5 runs `git apply` against the freshly-cloned PDAL
source tree:

```sh
git apply -p3 --directory=vendor/lazperf <patch>
```

`-p3` strips the patch's `a/cpp/lazperf/` prefix to the bare filename;
`--directory=vendor/lazperf` then prepends PDAL's tree layout.
Idempotent — re-runs check `git apply --reverse --check` first and
skip if already applied.

## Verifying

After build, on `libpdalcpp.a` (any slice):

```sh
nm libpdalcpp.a | c++filt | grep "las_decompressor::reset"
```

Expect a definition for `las_decompressor::reset(InputCb)` and an
override for `point_decompressor_base_1_4::reset(InputCb)`. Same
symbols should appear in `copclib.xcframework`'s `liblazperf.a`.

## Updating

If upstream lazperf changes shape and the patch stops applying:

1. Refresh `SwiftPDAL/Frameworks/lazperf-patches/0001-add-reset-api.patch`
   first (it's developed against `hobuinc/laz-perf@master`, the easier
   target).
2. Copy it back here, then adjust context lines to match PDAL's
   vendored snapshot (see "two context lines" note above).
3. Confirm `git apply --check -p3 --directory=vendor/lazperf` is clean
   against the PDAL tag you're building.
