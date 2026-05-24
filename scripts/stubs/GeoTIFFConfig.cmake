# GeoTIFF stub for iOS — GeoTIFF is merged into gdal.xcframework's static
# archive, so the GeoTIFF *symbols* are present at link time. PDAL's
# find_package(GeoTIFF REQUIRED 1.7.0) still expects a CMake-side
# package. This stub satisfies the package query without binding a real
# library; the linker resolves GeoTIFF symbols through libgdal.
set(GEOTIFF_FOUND TRUE)
set(GeoTIFF_FOUND TRUE)
set(GEOTIFF_INCLUDE_DIR "")
set(GEOTIFF_LIBRARIES "")
if(NOT TARGET GEOTIFF::GEOTIFF)
    add_library(GEOTIFF::GEOTIFF INTERFACE IMPORTED)
endif()
