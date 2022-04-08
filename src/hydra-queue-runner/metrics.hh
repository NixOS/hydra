#pragma once

#include <prometheus/counter.h>
#include <prometheus/gauge.h>
#include <prometheus/histogram.h>
#include <prometheus/registry.h>

struct PromTimer
{
    std::chrono::time_point<std::chrono::high_resolution_clock> created;

    PromTimer()
        : created(std::chrono::high_resolution_clock::now())
    {

    }

public:
    void finish(prometheus::Histogram& histogram)
    {
        histogram.Observe(std::chrono::duration<double>(std::chrono::high_resolution_clock::now() - created).count());
    }
};


    struct PromMetrics
    {
        std::shared_ptr<prometheus::Registry> registry;

        prometheus::Counter& queue_checks_started;
        prometheus::Histogram& queue_build_fetch_time;
        prometheus::Family<prometheus::Histogram>& queue_build_load_family;
        prometheus::Histogram& queue_build_load_premature_gc;
        prometheus::Histogram& queue_build_load_cached_failure;
        prometheus::Histogram& queue_build_load_cached_success;
        prometheus::Histogram& queue_build_load_added;
        prometheus::Counter& queue_steps_created;
        prometheus::Counter& queue_checks_early_exits;
        prometheus::Counter& queue_checks_finished;
        prometheus::Gauge& queue_max_id;

        PromMetrics();
    };
