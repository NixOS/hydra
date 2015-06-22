#pragma once

#include <atomic>

typedef std::atomic<unsigned int> counter;

struct MaintainCount
{
    counter & c;
    MaintainCount(counter & c) : c(c) { c++; }
    ~MaintainCount() { c--; }
};
