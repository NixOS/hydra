# Hydra Jobs

## Derivation Attributes

Hydra stores the following job attributes in its database:

* `nixName` - the Derivation's `name` attribute
* `system` - the Derivation's `system` attribute
* `drvPath` - the Derivation's path in the Nix store
* `outputs` - A JSON dictionary of output names and their store path.

### Meta fields

* `description` - `meta.description`, a string
* `license` - a comma separated list of license names from `meta.license`, expected to be a list of attribute sets with an attribute named `shortName`, ex: `[ { shortName = "licensename"} ]`.
* `homepage` - `meta.homepage`, a string
* `maintainers` - a comma separated list of maintainer email addresses from `meta.maintainers`, expected to be a list of attribute sets with an attribute named `email`, ex: `[ { email = "alice@example.com"; } ]`.
* `schedulingPriority` - `meta.schedulingPriority`, an integer. Default: 100. Slightly prioritizes this job over other jobs within this jobset.
* `timeout` - `meta.timeout`, an integer. Default: 36000. Number of seconds this job must complete within.
* `maxSilent` - `meta.maxSilent`, an integer. Default: 7200. Number of seconds of no output on stderr / stdout before considering the job failed. 
* `isChannel` - `meta.isHydraChannel`, bool. Default: false. Deprecated.
