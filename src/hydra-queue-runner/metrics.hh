#pragma once

#include <cassert>
#include <prometheus/counter.h>
#include <prometheus/gauge.h>
#include <prometheus/histogram.h>
#include <prometheus/registry.h>

// Track the elapsed time of a code block, and manually submit the timing
// data to a prometheus Histogram.
struct PromTimerManual
{
    std::chrono::time_point<std::chrono::high_resolution_clock> created;

    PromTimerManual()
        : created(std::chrono::high_resolution_clock::now())
    {

    }

public:
    void finish(prometheus::Histogram& histogram)
    {
        histogram.Observe(std::chrono::duration<float>(std::chrono::high_resolution_clock::now() - created).count());
    }
};

// Track the elapsed time of a code block, automatically submitting the timingh
// data when the timer drops.
struct PromTimer
{
    PromTimerManual timer;
    prometheus::Histogram& histogram;

    PromTimer(prometheus::Histogram& metric)
        : histogram(metric)
    {
    }

    ~PromTimer() {
        timer.finish(histogram);
    }
};

// Track the elapsed time of a code block where multiple exits are possible.
//
// The timing will be submitted to the constructor's histogram if the timer
// drops before finish() was called manually.
//
// Complicated code paths should explicitly finish() every exit, leaving the
// default histogram as a way to track failures to properly track exits.
struct PromTimerExactlyOneExit
{
    PromTimerManual timer;
    std::optional<std::reference_wrapper<prometheus::Histogram>> histogram;

    PromTimerExactlyOneExit(prometheus::Histogram& default_metric)
        : histogram(default_metric)
    {
    }

    ~PromTimerExactlyOneExit() {
        if (histogram) {
            finish(histogram->get());
        }
    }

public:
    void finish(prometheus::Histogram& metric)
    {
        // Assert that we have not reported any metric yet,
        // as this timer should only be finish()'d once
        assert(histogram.has_value());
        histogram.reset();
        timer.finish(metric);
    }
};

struct PromMetrics
{
    std::shared_ptr<prometheus::Registry> registry;

    prometheus::Counter& queue_checks_started;
    prometheus::Histogram& queue_build_fetch_time;
    prometheus::Family<prometheus::Histogram>& queue_build_load_family;
    prometheus::Histogram& queue_build_load_missed_exit;
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
