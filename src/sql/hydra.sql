create table Users (
    userName      text primary key not null,
    fullName      text,
    emailAddress  text not null,
    password      text not null, -- sha256 hash
    emailOnError  integer not null default 0
);


create table UserRoles (
    userName      text not null,
    role          text not null,
    primary key   (userName, role),
    foreign key   (userName) references Users(userName) on delete cascade on update cascade
);


create table Projects (
    name          text primary key not null, -- project id, lowercase (e.g. "patchelf")
    displayName   text not null, -- display name (e.g. "PatchELF")
    description   text,
    enabled       integer not null default 1,
    hidden        integer not null default 0,
    owner         text not null,
    homepage      text, -- URL for the project
    foreign key   (owner) references Users(userName) on update cascade
);

create table ProjectMembers (
    project       text not null,
    userName      text not null,
    primary key   (project, userName),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (userName) references Users(userName) on delete cascade on update cascade
);


-- A jobset consists of a set of inputs (e.g. SVN repositories), one
-- of which contains a Nix expression containing an attribute set
-- describing build jobs.
create table Jobsets (
    name          text not null,
    project       text not null,
    description   text,
    nixExprInput  text not null, -- name of the jobsetInput containing the Nix expression
    nixExprPath   text not null, -- relative path of the Nix expression
    errorMsg      text, -- used to signal the last evaluation error etc. for this jobset
    errorTime     integer, -- timestamp associated with errorMsg
    lastCheckedTime integer, -- last time the evaluator looked at this jobset
    enabled       integer not null default 1,
    enableEmail   integer not null default 1,
    hidden        integer not null default 0,
    emailOverride text not null,
    keepnr        integer not null default 3,
    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade
#ifdef SQLITE
    ,
    foreign key   (project, name, nixExprInput) references JobsetInputs(project, jobset, name)
#endif
);


create table JobsetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "cvs", "path", "uri", "string", "boolean"
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


#ifdef POSTGRESQL
alter table Jobsets
  add foreign key (project, name, nixExprInput)
    references JobsetInputs(project, jobset, name);
#endif


create table JobsetInputAlts (
    project       text not null,
    jobset        text not null,
    input         text not null,
    altnr         integer not null,

    -- urgh
    value         text, -- for most types, a URI; for 'path', an absolute path; for 'string', an arbitrary value
    revision      text, -- for type == 'svn'
    tag           text, -- for type == 'cvs'
    
    primary key   (project, jobset, input, altnr),
    foreign key   (project, jobset, input) references JobsetInputs(project, jobset, name) on delete cascade on update cascade
);


create table Jobs (
    project       text not null,
    jobset        text not null,
    name          text not null,

    active        integer not null default 1, -- !!! obsolete, remove

    errorMsg      text, -- evalution error for this job

    firstEvalTime integer, -- first time the evaluator saw this job
    lastEvalTime  integer, -- last time the evaluator saw this job

    disabled      integer not null default 0, -- !!! not currently used

    primary key   (project, jobset, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


-- This table contains all wbuilds, either scheduled or finished.  For
-- scheduled builds, additional info (such as the priority) can be
-- found in the BuildSchedulingInfo table.  For finished builds,
-- additional info (such as the logs, build products, etc.) can be
-- found in several tables, such as BuildResultInfo and BuildProducts.
create table Builds (
#ifdef POSTGRESQL
    id            serial primary key not null,
#else
    id            integer primary key autoincrement not null,
#endif

    finished      integer not null, -- 0 = scheduled, 1 = finished
    
    timestamp     integer not null, -- time this build was scheduled / finished building

    -- Info about the inputs.
    project       text not null,
    jobset        text not null,
    job           text not null,

    -- Info about the build result.
    nixName       text, -- name attribute of the derivation
    description   text, -- meta.description
    drvPath       text not null,
    outPath       text not null,
    system        text not null,

    longDescription text, -- meta.longDescription
    license       text, -- meta.license
    homepage      text, -- meta.homepage
    maintainers   text, -- meta.maintainers (concatenated, comma-separated)
    maxsilent     integer default 3600, -- meta.maxsilent
    timeout       integer default 36000, -- meta.timeout

    isCurrent     integer default 0,

    -- Copy of the nixExprInput/nixExprPath fields of the jobset that
    -- instantiated this build.  Needed if we want to clone this
    -- build.
    nixExprInput  text,
    nixExprPath   text,
    
    foreign key   (project) references Projects(name) on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade
);


-- Info for a scheduled build.
create table BuildSchedulingInfo (
    id            integer primary key not null,
    
    priority      integer not null default 0,

    busy          integer not null default 0, -- true means someone is building this job now
    locker        text not null default '', -- !!! hostname/pid of the process building this job?

    logfile       text, -- if busy, the path of the logfile

    disabled      integer not null default 0,
    
    startTime     integer, -- if busy, time we started
    
    foreign key   (id) references Builds(id) on delete cascade
);


-- Info for a finished build.
create table BuildResultInfo (
    id            integer primary key not null,
    
    isCachedBuild integer not null, -- boolean

    -- Status codes:
    --   0 = succeeded
    --   1 = build of this derivation failed
    --   2 = build of some dependency failed
    --   3 = other failure (see errorMsg)
    --   4 = build cancelled (removed from queue; never built)
    --   5 = build not done because a dependency failed previously (obsolete)
    buildStatus   integer,

    errorMsg      text, -- error message in case of a Nix failure
    
    startTime     integer, -- in Unix time, 0 = used cached build result
    stopTime      integer,

    logfile       text, -- the path of the logfile

    logsize       bigint not null default 0,
    size          bigint not null default 0,
    closuresize   bigint not null default 0,

    releaseName   text, -- e.g. "patchelf-0.5pre1234"

    keep          integer not null default 0, -- true means never garbage-collect the build output

    failedDepBuild  integer, -- obsolete
    failedDepStepNr integer, -- obsolete
    
    foreign key   (id) references Builds(id) on delete cascade
);


create table BuildSteps (
    build         integer not null,
    stepnr        integer not null,

    type          integer not null, -- 0 = build, 1 = substitution

    drvPath       text,
    outPath       text,

    logfile       text,

    busy          integer not null,

    status        integer, -- 0 = success, 1 = failed

    errorMsg      text,

    startTime     integer,
    stopTime      integer,

    machine       text not null default '',
    system        text,

    primary key   (build, stepnr),
    foreign key   (build) references Builds(id) on delete cascade
);


-- Inputs of builds.
create table BuildInputs (
#ifdef POSTGRESQL
    id            serial primary key not null,
#else
    id            integer primary key autoincrement not null,
#endif

    -- Which build this input belongs to.
    build         integer,
    
    -- Copied from the jobsetinputs from which the build was created.
    name          text not null,
    type          text not null,
    uri           text,
    revision      text,
    tag           text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,
    
    sha256hash    text,
    
    foreign key   (build) references Builds(id) on delete cascade,
    foreign key   (dependency) references Builds(id)
);


create table BuildProducts (
    build         integer not null,
    productnr     integer not null,
    type          text not null, -- "nix-build", "file", "doc", "report", ...
    subtype       text not null, -- "source-dist", "rpm", ...
    fileSize      integer,
    sha1hash      text,
    sha256hash    text,
    path          text,
    name          text not null, -- generally just the filename part of `path'
    description   text, -- optionally, some description of this file/directory
    defaultPath   text, -- if `path' is a directory, the default file relative to `path' to be served
    primary key   (build, productnr),
    foreign key   (build) references Builds(id) on delete cascade
);


-- Cache for inputs of type "path" (used for testing Hydra), storing
-- the SHA-256 hash and store path for each source path.  Also stores
-- the timestamp when we first saw the path have these contents, which
-- may be used to generate release names.
create table CachedPathInputs (
    srcPath       text not null,
    timestamp     integer not null, -- when we first saw this hash
    lastSeen      integer not null, -- when we last saw this hash
    sha256hash    text not null,
    storePath     text not null,
    primary key   (srcPath, sha256hash)
);


create table CachedSubversionInputs (
    uri           text not null,
    revision      integer not null,
    sha256hash    text not null,
    storePath     text not null,
    primary key   (uri, revision)
);

create table CachedGitInputs (
    uri           text not null,
    branch        text not null,
    revision      text not null,
    sha256hash    text not null,
    storePath     text not null,
    primary key   (uri, branch, revision)
);

create table CachedHgInputs (
    uri           text not null,
    branch        text not null,
    revision      text not null,
    sha256hash    text not null,
    storePath     text not null,
    primary key   (uri, branch, revision)
);

create table CachedCVSInputs (
    uri           text not null,
    module        text not null,
    timestamp     integer not null, -- when we first saw this hash
    lastSeen      integer not null, -- when we last saw this hash
    sha256hash    text not null,
    storePath     text not null,
    primary key   (uri, module, sha256hash)
);


create table SystemTypes (
    system        text primary key not null,
    maxConcurrent integer not null default 2
);


-- Views are a mechanism to automatically group related builds
-- together.  A view definition consists of a build of some "primary"
-- job, plus all builds of the other jobs named in ViewJobs that have
-- that build as an input.  If there are multiple builds matching a
-- ViewJob, then we take the oldest successful build, or the oldest
-- unsuccessful build if there is no successful build.
create table Views (
    project       text not null,
    name          text not null,
    
    description   text,

    -- If true, don't garbage-collect builds included in this view.
    keep          integer not null default 0, 

    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade
);


create table ViewJobs (
    project       text not null,
    view_         text not null,

    job           text not null,

    -- A constraint on the job consisting of `name=value' pairs,
    -- e.g. "system=i686-linux officialRelease=true".  Should really
    -- be a separate table but I'm lazy.
    attrs         text not null,

    -- If set, this is the primary job for the view.  There can be
    -- only one such job per view.
    isPrimary     integer not null default 0,
    
    description   text,
    
    jobset        text not null,

    -- If set, once there is a successful build for every job
    -- associated with a build of the view's primary job, that set of
    -- builds is automatically added as a release to the Releases
    -- table.
    autoRelease   integer not null default 0,
    
    primary key   (project, view_, job, attrs),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, view_) references Views(project, name) on delete cascade on update cascade
);


-- A release is a named set of builds.  The ReleaseMembers table lists
-- the builds that constitute each release.
create table Releases (
    project       text not null,
    name          text not null,

    timestamp     integer not null,

    description   text,

    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade
);


create table ReleaseMembers (
    project       text not null,
    release_      text not null,
    build         integer not null,

    description   text,

    primary key   (project, release_, build),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, release_) references Releases(project, name) on delete cascade on update cascade,
    foreign key   (build) references Builds(id)
);


create table JobsetEvals (
#ifdef POSTGRESQL
    id            serial primary key not null,
#else
    id            integer primary key autoincrement not null,
#endif

    project       text not null,
    jobset        text not null,
    
    timestamp     integer not null, -- when this entry was added
    checkoutTime  integer not null, -- how long obtaining the inputs took (in seconds)
    evalTime      integer not null, -- how long evaluation took (in seconds)

    -- If 0, then the evaluation of this jobset did not cause any new
    -- builds to be added to the database.  Otherwise, *all* the
    -- builds resulting from the evaluation of the jobset (including
    -- existing ones) can be found in the JobsetEvalMembers table.
    hasNewBuilds  integer not null,

    -- Used to prevent repeated Nix expression evaluation for the same
    -- set of inputs for a jobset.  In the evaluator, after obtaining
    -- the current inputs for a jobset, we hash the inputs together,
    -- and if the resulting hash already appears in this table, we can
    -- skip the jobset.  Otherwise we proceed.  The hash is computed
    -- over the command-line arguments to hydra_eval_jobs.
    hash          text not null,

    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


create table JobsetEvalMembers (
    eval          integer not null references JobsetEvals(id) on delete cascade,
    build         integer not null references Builds(id) on delete cascade,
    isNew         integer not null,
    primary key   (eval, build)
);


create table UriRevMapper (
    baseuri       text not null,
    uri           text not null,
    primary key   (baseuri)
);

create table NewsItems (
#ifdef POSTGRESQL
    id            serial primary key not null,
#else
    id            integer primary key autoincrement not null,
#endif
    contents      text not null,
    createTime    integer not null,
    author        text not null,
    foreign key   (author) references Users(userName) on delete cascade on update cascade
);

create table BuildMachines (
    hostname text primary key NOT NULL,
    username text DEFAULT '' NOT NULL,
    ssh_key text DEFAULT '' NOT NULL,
    options text DEFAULT '' NOT NULL,
    maxconcurrent integer DEFAULT 2 NOT NULL,
    speedfactor integer DEFAULT 1 NOT NULL,
    enabled integer DEFAULT 0 NOT NULL
);

create table BuildMachineSystemTypes (
    hostname text NOT NULL,
    system text NOT NULL,
    primary key (hostname, system),
    foreign key (hostname) references BuildMachines(hostname) on delete cascade
);

-- Some indices.
create index IndexBuildInputsOnBuild on BuildInputs(build);
create index IndexBuildInputsOnDependency on BuildInputs(dependency);
create index IndexBuildProducstOnBuildAndType on BuildProducts(build, type);
create index IndexBuildProductsOnBuild on BuildProducts(build);
create index IndexBuildResultInfo on BuildResultInfo(id); -- primary key index, not created automatically by PostgreSQL
create index IndexBuildSchedulingInfoOnBuild on BuildSchedulingInfo(id); -- idem
create index IndexBuildStepsOnBuild on BuildSteps(build);
create index IndexBuildStepsOnDrvpathTypeBusyStatus on BuildSteps(drvpath, type, busy, status);
create index IndexBuildStepsOnOutpath on BuildSteps(outpath);
create index IndexBuildStepsOnOutpathBuild on BuildSteps (outpath, build);
create index IndexBuildsOnFinished on Builds(finished);
create index IndexBuildsOnIsCurrent on Builds(isCurrent);
--create index IndexBuildsOnJob on Builds(project, jobset, job);
--create index IndexBuildsOnJobAndIsCurrent on Builds(project, jobset, job, isCurrent);
create index IndexBuildsOnJobAndSystem on Builds(project, jobset, job, system);
create index IndexBuildsOnJobset on Builds(project, jobset);
create index IndexBuildsOnProject on Builds(project);
create index IndexBuildsOnTimestamp on Builds(timestamp);
create index IndexBuildsOnJobFinishedId on builds(project, jobset, job, system, finished, id DESC);
create index IndexBuildsOnDrvPath on Builds(drvPath);
create index IndexCachedHgInputsOnHash on CachedHgInputs(uri, branch, sha256hash);
create index IndexCachedGitInputsOnHash on CachedGitInputs(uri, branch, sha256hash);
create index IndexCachedSubversionInputsOnUriRevision on CachedSubversionInputs(uri, revision);
create index IndexJobsetEvalMembersOnBuild on JobsetEvalMembers(build);
create index IndexJobsetInputAltsOnInput on JobsetInputAlts(project, jobset, input);
create index IndexJobsetInputAltsOnJobset on JobsetInputAlts(project, jobset);
create index IndexProjectsOnEnabled on Projects(enabled);
create index IndexReleaseMembersOnBuild on ReleaseMembers(build);
