{
  host
, appKey
, apiKey
, ...
}:
{
  resources.datadogTimeboards.dash = {
    inherit appKey apiKey;
    description = "Hydra build farm status (hydra.nixos.org)";
    graphs = [
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.steps.active{$host}"; }
            { q = "avg:hydra.queue.steps.building{$host}"; }
            { q = "avg:hydra.queue.steps.copying_to{$host}"; }
            { q = "avg:hydra.queue.steps.copying_from{$host}"; }
            { q = "avg:hydra.queue.steps.waiting{$host}"; }
          ];
          viz = "timeseries";
        };
        title = "Active/building steps";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.steps.avg_build_time{$host}"; }
            { q = "avg:hydra.queue.steps.avg_total_time{$host}"; }
          ];
          viz = "timeseries";
        };
        title = "Build/total time per step";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.steps.finished{$host}"; }
            { q = "avg:hydra.queue.builds.finished{$host}"; }
          ];
          viz = "timeseries";
        };
        title = "Finished builds/steps";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "max:system.io.await{$host} by {device}"; type = "area"; }
          ];
          viz = "timeseries";
        };
        title = "Disk latency (ms, by device)";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.steps.unfinished{$host}"; }
            { q = "avg:hydra.queue.builds.unfinished{$host}"; }
            { q = "avg:hydra.queue.steps.runnable{$host}"; }
          ];
          viz = "timeseries";
        };
        title = "Unfinished builds/steps";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:system.load.1{$host}"; }
            { q = "avg:system.load.5{$host}"; }
            { q = "avg:system.load.15{$host}"; }
          ];
          viz = "timeseries";
        };
        title = "Load Averages 1-5-15";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "per_hour(ewma_20(avg:hydra.queue.steps.finished{$host}))"; }
            {
              q = "per_hour(ewma_20(avg:hydra.queue.builds.finished{$host}))";
            }
          ];
          viz = "timeseries";
        };
        title = "Finished builds/steps / hour";
      }
      {
        definition = builtins.toJSON {
          requests = [ { q = "avg:hydra.mem.dirty{$host}"; } ];
          viz = "timeseries";
        };
        title = "Dirty memory";
      }
      {
        definition = builtins.toJSON {
          requests = [
            {
              aggregator = "avg";
              conditional_formats = [];
              q = "avg:system.mem.used{$host}";
              type = "line";
            }
            {
              conditional_formats = [];
              q = "avg:system.mem.free{$host}";
              type = "line";
            }
            {
              conditional_formats = [];
              q = "avg:system.mem.usable{$host}";
              type = "line";
            }
          ];
          viz = "timeseries";
        };
        title = "Memory usage";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.bytes_sent{$host}"; type = "line"; }
            { q = "avg:hydra.queue.bytes_received{$host}"; type = "line"; }
          ];
          viz = "timeseries";
        };
        title = "Stores paths sent/received";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "per_minute(ewma_20(avg:hydra.queue.bytes_sent{$host}))"; }
            {
              q = "per_minute(ewma_20(avg:hydra.queue.bytes_received{$host}))";
            }
          ];
          viz = "timeseries";
        };
        title = "Store paths sent/received (GiB / minute)";
      }
      {
        definition = builtins.toJSON {
          requests = [
            { q = "avg:hydra.queue.machines.total{$host}"; type = "line"; }
            { q = "avg:hydra.queue.machines.in_use{$host}"; type = "line"; }
          ];
          viz = "timeseries";
        };
        title = "Total and active machines";
      }
    ];
    templateVariables = [
      {
        default = "host:${host}";
        name = "host";
        prefix = "host";
      }
    ];
    title = "Hydra Status (deployed from nixops)";
  };
}
