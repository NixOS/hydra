use Cwd;
use strict;
use warnings;

die "$0: dbi connection string required \n" if scalar @ARGV != 1;

make_schema_at("Hydra::Schema", {
    naming => { ALL => "v5" },
    relationships => 1,
    use_namespaces => 1,
    overwrite_modifications => 1,
    moniker_map => {
        "aggregateconstituents" => "AggregateConstituents",
        "buildinputs" => "BuildInputs",
        "buildmetrics" => "BuildMetrics",
        "buildoutputs" => "BuildOutputs",
        "buildproducts" => "BuildProducts",
        "builds" => "Builds",
        "buildstepoutputs" => "BuildStepOutputs",
        "buildsteps" => "BuildSteps",
        "cachedbazaarinputs" => "CachedBazaarInputs",
        "cachedcvsinputs" => "CachedCVSInputs",
        "cacheddarcsinputs" => "CachedDarcsInputs",
        "cachedgitinputs" => "CachedGitInputs",
        "cachedhginputs" => "CachedHgInputs",
        "cachedpathinputs" => "CachedPathInputs",
        "cachedsubversioninputs" => "CachedSubversionInputs",
        "evaluationerrors" => "EvaluationErrors",
        "failedpaths" => "FailedPaths",
        "jobsetevalinputs" => "JobsetEvalInputs",
        "jobsetevalmembers" => "JobsetEvalMembers",
        "jobsetevals" => "JobsetEvals",
        "jobsetinputalts" => "JobsetInputAlts",
        "jobsetinputs" => "JobsetInputs",
        "jobsetrenames" => "JobsetRenames",
        "jobsets" => "Jobsets",
        "newsitems" => "NewsItems",
        "nrbuilds" => "NrBuilds",
        "projectmembers" => "ProjectMembers",
        "projects" => "Projects",
        "runcommandlogs" => "RunCommandLogs",
        "schemaversion" => "SchemaVersion",
        "starredjobs" => "StarredJobs",
        "systemstatus" => "SystemStatus",
        "taskretries" => "TaskRetries",
        "urirevmapper" => "UriRevMapper",
        "userroles" => "UserRoles",
        "users" => "Users",
    } , #sub { return "$_"; },
    components => [ "+Hydra::Component::ToJSON" ],
    # Composite (storeDir, ...) foreign keys make Schema::Loader generate
    # verbose relationship names; map the relations existing code uses back
    # to their canonical names. Where a table has both a single-column and
    # a composite foreign key to the same parent, the single-column one
    # keeps the canonical name.
    rel_name_map => {
        Builds => {
            buildsteps_storedir_builds => "buildsteps",
            buildoutputs_builds => "buildoutputs",
            buildproducts_builds => "buildproducts",
        },
        BuildSteps => {
            build_storedir_build => "build",
            buildstepoutputs_build_stepnrs => "buildstepoutputs",
        },
        BuildStepOutputs => {
            buildstep_build_stepnr => "buildstep",
        },
    }
}, [$ARGV[0]]);
