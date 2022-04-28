This is a rough overview from informal discussions and explanations of inner workings of Hydra.
You can use it as a guide to navigate the codebase or ask questions.

## Architecture

### Components

- Postgres database
    - configuration
    - build queue
        - what is already built
        - what is going to build
- `hydra-server`
    - Perl, Catalyst
    - web frontend
- `hydra-evaluator`
    - Perl, C++
    - fetches repositories
    - evaluates job sets
        - pointers to a repository
    - adds builds to the queue
- `hydra-queue-runner`
    - C++
    - monitors the queue
    - executes build steps
    - uploads build results
        - copy to a Nix store
- Nix store
    - contains `.drv`s
    - populated by `hydra-evaluator`
    - read by `hydra-queue-runner`
- destination Nix store
    - can be a binary cache
    - e.g. `[cache.nixos.org](http://cache.nixos.org)` or the same store again (for small Hydra instances)
- plugin architecture
    - extend evaluator for new kinds of repositories
        - e.g. fetch from `git`

### Database Schema

[https://github.com/NixOS/hydra/blob/master/src/sql/hydra.sql](https://github.com/NixOS/hydra/blob/master/src/sql/hydra.sql)

- `Jobsets`
    - populated by calling Nix evaluator
    - every Nix derivation in `release.nix` is a Job
    - `flake`
        - URL to flake, if job is from a flake
        - single-point of configuration for flake builds
        - flake itself contains pointers to dependencies
        - for other builds we need more configuration data
- `JobsetInputs`
    - more configuration for a Job
- `JobsetInputAlts`
    - historical, where you could have more than one alternative for each input
    - it would have done the cross product of all possibilities
    - not used any more, as now every input is unique
    - originally that was to have alternative values for the system parameter
        - `x86-linux`, `x86_64-darwin`
        - turned out not to be a good idea, as job set names did not uniquely identify output
- `Builds`
    - queue: scheduled and finished builds
    - instance of a Job
    - corresponds to a top-level derivation
        - can have many dependencies that don’t have a corresponding build
        - dependencies represented as `BuildSteps`
    - a Job is all the builds with a particular name, e.g.
        - `git.x86_64-linux` is a job
        - there maybe be multiple builds for that job
            - build ID: just an auto-increment number
    - building one thing can actually cause many (hundreds of) derivations to be built
    - for queued builds, the `drv` has to be present in the store
        - otherwise build will fail, e.g. after garbage collection
- `BuildSteps`
    - corresponds to a derivation or substitution
    - are reused through the Nix store
    - may be duplicated for unique derivations due to how they relate to `Jobs`
- `BuildStepOutputs`
    - corresponds directly to derivation outputs
        - `out`, `dev`, ...
- `BuildProducts`
    - not a Nix concept
    - populated from a special file `$out/nix-support/hydra-build-producs`
    - used to scrape parts of build results out to the web frontend
        - e.g. manuals, ISO images, etc.
- `BuildMetrics`
    - scrapes data from magic location, similar to `BuildProducts` to show fancy graphs
        - e.g. test coverage, build times, CPU utilization for build
    - `$out/nix-support/hydra-metrics`
- `BuildInputs`
    - probably obsolute
- `JobsetEvalMembers`
    - joins evaluations with jobs
    - huge table, 10k’s of entries for one `nixpkgs` evaluation
    - can be imagined as a subset of the eval cache
        - could in principle use the eval cache

### `release.nix`

- hydra-specific convention to describe the build
- should evaluate to an attribute set that contains derivations
- hydra considers every attribute in that set a job
- every job needs a unique name
    - if you want to build for multiple platforms, you need to reflect that in the name
- hydra does a deep traversal of the attribute set
    - just evaluating the names may take half an hour

## FAQ

Can we imagine Hydra to be a persistence layer for the build graph?

- partially, it lacks a lot of information
  - does not keep edges of the build graph

How does Hydra relate to `nix build`?

- reimplements the top level Nix build loop, scheduling, etc.
- Hydra has to persist build results
- Hydra has more sophisticated remote build execution and scheduling than Nix

Is it conceptually possible to unify Hydra’s capabilities with regular Nix?

- Nix does not have any scheduling, it just traverses the build graph
- Hydra has scheduling in terms of job set priorities, tracks how much of a job set it has worked on
    - makes sure jobs don’t starve each other
- Nix cannot dynamically add build jobs at runtime
    - [RFC 92](https://github.com/NixOS/rfcs/blob/master/rfcs/0092-plan-dynamism.md) should enable that
    - internally it is already possible, but there is no interface to do that
- Hydra queue runner is a long running process
    - Nix takes a static set of jobs, working it off at once
