/* Thin C ABI for the iOS verify harness.
 *
 * `verify_e57_reader_registered` constructs a PDAL StageFactory and
 * asks it for "readers.e57". A non-NULL return proves that:
 *   1. pdalcpp + E57Format + gdal + proj linked cleanly,
 *   2. the static-init shim wired the E57 reader into PDAL's plugin
 *      registry (CREATE_STATIC_STAGE path),
 *   3. the consumer link pulled the E57Reader registrar global in.
 */

#ifndef IOSSAMPLE_CXX_H
#define IOSSAMPLE_CXX_H

#ifdef __cplusplus
extern "C" {
#endif

int verify_e57_reader_registered(void);
int verify_las_reader_registered(void);

#ifdef __cplusplus
}
#endif

#endif
