#pragma once

#include <atomic>
#include <functional>

typedef std::atomic<unsigned long> counter;

struct MaintainCount
{
    counter & c;
    MaintainCount(counter & c) : c(c) { c++; }
    MaintainCount(counter & c, std::function<void(unsigned long)> warn) : c(c)
    {
        warn(++c);
    }
    ~MaintainCount() { auto prev = c--; assert(prev); }
};
