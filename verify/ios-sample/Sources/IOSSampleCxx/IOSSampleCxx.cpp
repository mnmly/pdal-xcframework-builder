#include "IOSSampleCxx.h"

#include <pdal/StageFactory.hpp>
#include <pdal/Stage.hpp>

extern "C" int verify_e57_reader_registered(void)
{
    pdal::StageFactory factory;
    pdal::Stage* stage = factory.createStage("readers.e57");
    return stage != nullptr ? 1 : 0;
}

extern "C" int verify_las_reader_registered(void)
{
    pdal::StageFactory factory;
    pdal::Stage* stage = factory.createStage("readers.las");
    return stage != nullptr ? 1 : 0;
}
