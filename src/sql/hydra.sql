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
    owner         text not null,
    homepage      text, -- URL for the project
    foreign key   (owner) references Users(userName) on update cascade
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
    lastCheckedTime integer, -- last time the scheduler looked at this jobset
    enabled       integer not null default 1,
    enableEmail   integer not null default 1,
    emailOverride text not null,
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

    firstEvalTime integer, -- first time the scheduler saw this job
    lastEvalTime  integer, -- last time the scheduler saw this job

    disabled      integer not null default 0, -- !!! not currently used

    primary key   (project, jobset, name),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


-- This table contains all builds, either scheduled or finished.  For
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
    timestamp     integer not null, -- when we first saw this hash
    lastSeen      integer not null, -- when we last saw this hash
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


-- This table is used to prevent repeated Nix expression evaluation
-- for the same set of inputs for a jobset.  In the scheduler, after
-- obtaining the current inputs for a jobset, we hash the inputs
-- together, and if the resulting hash already appears in this table,
-- we can skip the jobset.  Otherwise it's added to the table, and the
-- Nix expression for the jobset is evaluated.  The hash is computed
-- over the command-line arguments to hydra_eval_jobs.
create table JobsetInputHashes (
    project       text not null,
    jobset        text not null,
    hash          text not null,
    timestamp     integer not null,
    primary key   (project, jobset, hash),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade on update cascade
);


-- Some indices.
create index IndexBuildInputsByBuild on BuildInputs(build);
create index IndexBuildInputsByDependency on BuildInputs(dependency);
create index IndexBuildsByTimestamp on Builds(timestamp);
create index IndexBuildsByIsCurrent on Builds(isCurrent);
create index IndexBuildsByFinished on Builds(finished);
create index IndexBuildsByProject on Builds(project);
create index IndexBuildsByJobset on Builds(project, jobset);
create index IndexBuildsByJob on Builds(project, jobset, job);
create index IndexBuildsByJobAndSystem on Builds(project, jobset, job, system);
create index IndexBuildResultInfo on BuildResultInfo(id); -- primary key index, not created automatically by PostgreSQL
create index IndexBuildSchedulingInfoByBuild on BuildSchedulingInfo(id); -- idem
create index IndexBuildProductsByBuild on BuildProducts(build);
create index IndexBuildProducstByBuildAndType on BuildProducts(build, type);
create index IndexBuildStepsByBuild on BuildSteps(build);


#ifdef SQLITE

-- Emulate some "on delete/update cascade" foreign key constraints,
-- which SQLite doesn't support yet.


create trigger cascadeBuildDeletion
  before delete on Builds
  for each row begin
    delete from BuildSchedulingInfo where id = old.id;
    delete from BuildResultInfo where id = old.id;
    delete from BuildInputs where build = old.id;
    delete from BuildProducts where build = old.id;
    delete from BuildSteps where build = old.id;
  end;


create trigger cascadeProjectUpdate
  update of name on Projects
  for each row begin
    update Jobsets set project = new.name where project = old.name;
    update JobsetInputs set project = new.name where project = old.name;
    update JobsetInputAlts set project = new.name where project = old.name;
    update Builds set project = new.name where project = old.name;
    update Views set project = new.name where project = old.name;
    update ViewJobs set project = new.name where project = old.name;
  end;


create trigger cascadeJobsetUpdate
  update of name on Jobsets
  for each row begin
    update JobsetInputs set jobset = new.name where project = old.project and jobset = old.name;
    update JobsetInputAlts set jobset = new.name where project = old.project and jobset = old.name;
    update Builds set jobset = new.name where project = old.project and jobset = old.name;
  end;


create trigger cascadeJobsetInputUpdate
  update of name on JobsetInputs
  for each row begin
    update JobsetInputAlts set input = new.name where project = old.project and jobset = old.jobset and input = old.name;
  end;


create trigger cascadeJobsetInputDelete
  before delete on JobsetInputs
  for each row begin
    delete from JobsetInputAlts where project = old.project and jobset = old.jobset and input = old.name;
  end;


create trigger cascadeUserDelete
  before delete on Users
  for each row begin
    delete from UserRoles where userName = old.userName;
  end;

  
create trigger cascadeViewDelete
  before delete on Views
  for each row begin
    delete from ViewJobs where project = old.project and view_ = old.name;
  end;


create trigger cascadeViewUpdate
  update of name on Views
  for each row begin
    update ViewJobs set view_ = new.name where project = old.project and view_ = old.name;
  end;

  
#endif
