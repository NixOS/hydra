#pragma once

#include <atomic>

typedef std::atomic<unsigned long> counter;

struct MaintainCount
{
    counter & c;
    MaintainCount(counter & c) : c(c) { c++; }
    ~MaintainCount() { c--; }
};
