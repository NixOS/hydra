-- Singleton table to keep track of the schema version.
create table SchemaVersion (
    version       integer not null
);


create table Users (
    userName      text primary key not null,
    fullName      text,
    emailAddress  text not null,
    password      text not null, -- sha256 hash
    emailOnError  integer not null default 0,
    type          text not null default 'hydra' -- either "hydra" or "persona"
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
    nixExprInput  text not null, -- name of the jobsetInput containing the Nix or Guix expression
    nixExprPath   text not null, -- relative path of the Nix or Guix expression
    errorMsg      text, -- used to signal the last evaluation error etc. for this jobset
    errorTime     integer, -- timestamp associated with errorMsg
    lastCheckedTime integer, -- last time the evaluator looked at this jobset
    triggerTime   integer, -- set if we were triggered by a push event
    enabled       integer not null default 1, -- 0 = disabled, 1 = enabled, 2 = one-shot
    enableEmail   integer not null default 1,
    hidden        integer not null default 0,
    emailOverride text not null,
    keepnr        integer not null default 3,
    checkInterval integer not null default 300, -- minimum time in seconds between polls (0 = disable polling)
    schedulingShares integer not null default 100,
    fetchErrorMsg text,
    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade
#ifdef SQLITE
    ,
    foreign key   (project, name, nixExprInput) references JobsetInputs(project, jobset, name)
#endif
);


create table JobsetRenames (
    project       text not null,
    from_         text not null,
    to_           text not null,
    primary key   (project, from_),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, to_) references Jobsets(project, name) on delete cascade on update cascade
);


create table JobsetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "path", "uri", "string", "boolean", "nix"
    emailResponsible integer not null default 0, -- whether to email committers to this input who change a build
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


create table JobsetInputAlts (
    project       text not null,
    jobset        text not null,
    input         text not null,
    altnr         integer not null,

    -- urgh
    value         text, -- for most types, a URI; for 'path', an absolute path; for 'string', an arbitrary value
    revision      text, -- for repositories

    primary key   (project, jobset, input, altnr),
    foreign key   (project, jobset, input) references JobsetInputs(project, jobset, name) on delete cascade on update cascade
);


create table Jobs (
    project       text not null,
    jobset        text not null,
    name          text not null,

    primary key   (project, jobset, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


create table Builds (
#ifdef POSTGRESQL
    id            serial primary key not null,
#else
    id            integer primary key autoincrement not null,
#endif

    finished      integer not null, -- 0 = scheduled, 1 = finished

    timestamp     integer not null, -- time this build was added

    -- Info about the inputs.
    project       text not null,
    jobset        text not null,
    job           text not null,

    -- Info about the build result.
    nixName       text, -- name attribute of the derivation
    description   text, -- meta.description
    drvPath       text not null,
    system        text not null,

    longDescription text, -- meta.longDescription
    license       text, -- meta.license
    homepage      text, -- meta.homepage
    maintainers   text, -- meta.maintainers (concatenated, comma-separated)
    maxsilent     integer default 3600, -- meta.maxsilent
    timeout       integer default 36000, -- meta.timeout

    isCurrent     integer default 0,

    -- Copy of the nixExprInput/nixExprPath fields of the jobset that
    -- instantiated this build.  Needed if we want to reproduce this
    -- build.
    nixExprInput  text,
    nixExprPath   text,

    -- Information about scheduled builds.
    priority      integer not null default 0,

    busy          integer not null default 0, -- true means someone is building this job now
    locker        text, -- !!! hostname/pid of the process building this job?

    logfile       text, -- if busy, the path of the logfile

    startTime     integer, -- if busy/finished, time we started
    stopTime      integer, -- if finished, time we finished

    -- Information about finished builds.
    isCachedBuild integer, -- boolean

    -- Status codes:
    --   0 = succeeded
    --   1 = build of this derivation failed
    --   2 = build of some dependency failed
    --   3 = other failure (see errorMsg)
    --   4 = build cancelled (removed from queue; never built)
    --   5 = build not done because a dependency failed previously (obsolete)
    --   6 = failure with output
    buildStatus   integer,

    errorMsg      text, -- error message in case of a Nix failure

    size          bigint,
    closureSize   bigint,

    releaseName   text, -- e.g. "patchelf-0.5pre1234"

    keep          integer not null default 0, -- true means never garbage-collect the build output

    check (finished = 0 or (stoptime is not null and stoptime != 0)),
    check (finished = 0 or (starttime is not null and starttime != 0)),

    foreign key   (project) references Projects(name) on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade
);


create table BuildOutputs (
    build         integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, name),
    foreign key   (build) references Builds(id) on delete cascade
);


create table BuildSteps (
    build         integer not null,
    stepnr        integer not null,

    type          integer not null, -- 0 = build, 1 = substitution

    drvPath       text,

    busy          integer not null,

    -- Status codes:
    --   0 = succeeded
    --   1 = failed normally
    --   4 = aborted
    --   7 = timed out
    --   8 = cached failure
    status        integer,

    errorMsg      text,

    startTime     integer,
    stopTime      integer,

    machine       text not null default '',
    system        text,

    primary key   (build, stepnr),
    foreign key   (build) references Builds(id) on delete cascade
);


create table BuildStepOutputs (
    build         integer not null,
    stepnr        integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, stepnr, name),
    foreign key   (build) references Builds(id) on delete cascade,
    foreign key   (build, stepnr) references BuildSteps(build, stepnr) on delete cascade
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
    value         text,
    emailResponsible integer not null default 0,
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
    fileSize      bigint,
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

create table CachedBazaarInputs (
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

create table CachedDarcsInputs (
    uri           text not null,
    revision      text not null,
    sha256hash    text not null,
    storePath     text not null,
    revCount      integer not null,
    primary key   (uri, revision)
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
    -- over the command-line arguments to hydra-eval-jobs.
    hash          text not null,

    -- Cached stats about the builds.
    nrBuilds      integer,
    nrSucceeded   integer, -- set lazily when all builds are finished

    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


create table JobsetEvalInputs (
    eval          integer not null references JobsetEvals(id) on delete cascade,
    name          text not null,
    altNr         integer not null,

    -- Copied from the jobsetinputs from which the build was created.
    type          text not null,
    uri           text,
    revision      text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,

    sha256hash    text,

    primary key   (eval, name, altNr),
    foreign key   (dependency) references Builds(id)
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


create table AggregateConstituents (
    aggregate     integer not null references Builds(id) on delete cascade,
    constituent   integer not null references Builds(id) on delete cascade,
    primary key   (aggregate, constituent)
);


create table StarredJobs (
    userName      text not null,
    project       text not null,
    jobset        text not null,
    job           text not null,
    primary key   (userName, project, jobset, job),
    foreign key   (userName) references Users(userName) on update cascade on delete cascade,
    foreign key   (project) references Projects(name) on update cascade on delete cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade on delete cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade on delete cascade
);


-- Cache of the number of finished builds.
create table NrBuilds (
    what  text primary key not null,
    count integer not null
);

insert into NrBuilds(what, count) values('finished', 0);

#ifdef POSTGRESQL

create function modifyNrBuildsFinished() returns trigger as $$
  begin
    if ((tg_op = 'INSERT' and new.finished = 1) or
        (tg_op = 'UPDATE' and old.finished = 0 and new.finished = 1)) then
      update NrBuilds set count = count + 1 where what = 'finished';
    elsif ((tg_op = 'DELETE' and old.finished = 1) or
           (tg_op = 'UPDATE' and old.finished = 1 and new.finished = 0)) then
      update NrBuilds set count = count - 1 where what = 'finished';
    end if;
    return null;
  end;
$$ language plpgsql;

create trigger NrBuildsFinished after insert or update or delete on Builds
  for each row
  execute procedure modifyNrBuildsFinished();

#endif


-- Some indices.

create index IndexBuildInputsOnBuild on BuildInputs(build);
create index IndexBuildInputsOnDependency on BuildInputs(dependency);
create index IndexBuildProducstOnBuildAndType on BuildProducts(build, type);
create index IndexBuildProductsOnBuild on BuildProducts(build);
create index IndexBuildStepsOnBusy on BuildSteps(busy) where busy = 1;
create index IndexBuildStepsOnDrvPath on BuildSteps(drvpath);
create index IndexBuildStepOutputsOnPath on BuildStepOutputs(path);
create index IndexBuildsOnFinished on Builds(finished) where finished = 0;
create index IndexBuildsOnFinishedBusy on Builds(finished, busy) where finished = 0;
create index IndexBuildsOnIsCurrent on Builds(isCurrent) where isCurrent = 1;
create index IndexBuildsOnJobsetIsCurrent on Builds(project, jobset, isCurrent) where isCurrent = 1;
create index IndexBuildsOnJobIsCurrent on Builds(project, jobset, job, isCurrent) where isCurrent = 1;
create index IndexBuildsOnJobset on Builds(project, jobset);
create index IndexBuildsOnProject on Builds(project);
create index IndexBuildsOnTimestamp on Builds(timestamp);
create index IndexBuildsOnFinishedStopTime on Builds(finished, stoptime DESC);
create index IndexBuildsOnJobFinishedId on builds(project, jobset, job, system, finished, id DESC);
create index IndexBuildsOnDrvPath on Builds(drvPath);
create index IndexCachedHgInputsOnHash on CachedHgInputs(uri, branch, sha256hash);
create index IndexCachedGitInputsOnHash on CachedGitInputs(uri, branch, sha256hash);
create index IndexCachedSubversionInputsOnUriRevision on CachedSubversionInputs(uri, revision);
create index IndexCachedBazaarInputsOnUriRevision on CachedBazaarInputs(uri, revision);
create index IndexJobsetEvalMembersOnBuild on JobsetEvalMembers(build);
create index IndexJobsetEvalMembersOnEval on JobsetEvalMembers(eval);
create index IndexJobsetInputAltsOnInput on JobsetInputAlts(project, jobset, input);
create index IndexJobsetInputAltsOnJobset on JobsetInputAlts(project, jobset);
create index IndexProjectsOnEnabled on Projects(enabled);
create index IndexReleaseMembersOnBuild on ReleaseMembers(build);

--  For hydra-update-gc-roots.
create index IndexBuildsOnKeep on Builds(keep) where keep = 1;

-- To get the most recent eval for a jobset.
create index IndexJobsetEvalsOnJobsetId on JobsetEvals(project, jobset, hasNewBuilds, id desc);
