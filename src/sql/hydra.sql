-- This table contains all builds, either scheduled or finished.  For
-- scheduled builds, additional info (such as the priority) can be
-- found in the BuildSchedulingInfo table.  For finished builds,
-- additional info (such as the logs, build products, etc.) can be
-- found in several tables, such as BuildResultInfo and BuildProducts.
create table Builds (
    id            integer primary key autoincrement not null,

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
    
    foreign key   (project) references Projects(name), -- ignored by sqlite
    foreign key   (project, jobset) references Jobsets(project, name), -- ignored by sqlite
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) -- ignored by sqlite
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
    
    foreign key   (id) references Builds(id) on delete cascade -- ignored by sqlite
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
    
    foreign key   (id) references Builds(id) on delete cascade -- ignored by sqlite
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
    foreign key   (build) references Builds(id) on delete cascade -- ignored by sqlite
);


-- Inputs of builds.
create table BuildInputs ( 
    id            integer primary key autoincrement not null,

    -- Which build this input belongs to.
    build         integer,
    
    -- Copied from the jobsetinputs from which the build was created.
    name          text not null,
    type          text not null,
    uri           text,
    revision      integer,
    tag           text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,
    
    sha256hash    text,
    
    foreign key   (build) references Builds(id) on delete cascade, -- ignored by sqlite
    foreign key   (dependency) references Builds(id) -- ignored by sqlite
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
    foreign key   (build) references Builds(id) on delete cascade -- ignored by sqlite
);


-- Emulate "on delete cascade" foreign key constraints.
create trigger cascadeBuildDeletion
  before delete on Builds
  for each row begin
    delete from BuildSchedulingInfo where id = old.id;
    delete from BuildResultInfo where id = old.id;
    delete from BuildInputs where build = old.id;
    delete from BuildProducts where build = old.id;
    delete from BuildSteps where build = old.id;
  end;


create table Projects (
    name          text primary key not null, -- project id, lowercase (e.g. "patchelf")
    displayName   text not null, -- display name (e.g. "PatchELF")
    description   text,
    enabled       integer not null default 1,
    owner         text not null,
    homepage      text, -- URL for the project
    foreign key   (owner) references Users(userName) -- ignored by sqlite
);


create trigger cascadeProjectUpdate
  update of name on Projects
  for each row begin
    update Jobsets set project = new.name where project = old.name;
    update JobsetInputs set project = new.name where project = old.name;
    update JobsetInputAlts set project = new.name where project = old.name;
    update Builds set project = new.name where project = old.name;
    update ReleaseSets set project = new.name where project = old.name;
    update ReleaseSetJobs set project = new.name where project = old.name;
  end;


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
    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, name, nixExprInput) references JobsetInputs(project, jobset, name)
);


create trigger cascadeJobsetUpdate
  update of name on Jobsets
  for each row begin
    update JobsetInputs set jobset = new.name where project = old.project and jobset = old.name;
    update JobsetInputAlts set jobset = new.name where project = old.project and jobset = old.name;
    update Builds set jobset = new.name where project = old.project and jobset = old.name;
  end;


create table JobsetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "cvs", "path", "uri", "string", "boolean"
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade -- ignored by sqlite
);


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


create table JobsetInputAlts (
    project       text not null,
    jobset        text not null,
    input         text not null,
    altnr         integer not null,

    -- urgh
    value         text, -- for most types, a URI; for 'path', an absolute path; for 'string', an arbitrary value
    revision      integer, -- for type == 'svn'
    tag           text, -- for type == 'cvs'
    
    primary key   (project, jobset, input, altnr),
    foreign key   (project, jobset, input) references JobsetInputs(project, jobset, name) on delete cascade -- ignored by sqlite
);


create table Jobs (
    project       text not null,
    jobset        text not null,
    name          text not null,

    -- `active' means the Nix expression for the jobset currently
    -- contains this job.  Otherwise it's a job that has been removed
    -- from the expression.
    active        integer not null default 1,

    errorMsg      text, -- evalution error for this job

    firstEvalTime integer, -- first time the scheduler saw this job
    lastEvalTime  integer, -- last time the scheduler saw this job

    disabled      integer not null default 0,

    primary key   (project, jobset, name),
    foreign key   (project) references Projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade -- ignored by sqlite
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


create table SystemTypes (
    system        text primary key not null,
    maxConcurrent integer not null default 2
);


create table Users (
    userName      text primary key not null,
    fullName      text,
    emailAddress  text not null,
    password      text not null -- sha256 hash
);


create table UserRoles (
    userName      text not null,
    role          text not null,
    primary key   (userName, role),
    foreign key   (userName) references Users(userName) -- ignored by sqlite
);


create trigger cascadeUserDelete
  before delete on Users
  for each row begin
    delete from UserRoles where userName = old.userName;
  end;


-- Release sets are a mechanism to automatically group related builds
-- together.  A release set defines what an individual release
-- consists of, namely: a release consists of a build of some
-- "primary" job, plus all builds of the other jobs named in
-- ReleaseSetJobs that have that build as an input.  If there are
-- multiple builds matching a ReleaseSetJob, then we take the oldest
-- successful build, or the oldest unsuccessful build if there is no
-- successful build.  A release is itself considered successful if all
-- builds (except those for jobs that have mayFail set) are
-- successful.
--
-- Note that individual releases aren't separately stored in the
-- database, so they're really just a dynamic view on the universe of
-- builds, defined by a ReleaseSet.
create table ReleaseSets (
    project       text not null,
    name          text not null,
    
    description   text,

    -- If true, don't garbage-collect builds belonging to the releases
    -- defined by this row.
    keep          integer not null default 0, 

    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade -- ignored by sqlite
);


create trigger cascadeReleaseSetDelete
  before delete on ReleaseSets
  for each row begin
    delete from ReleaseSetJobs where project = old.project and release_ = old.name;
  end;


create trigger cascadeReleaseSetUpdate
  update of name on ReleaseSets
  for each row begin
    update ReleaseSetJobs set release_ = new.name where project = old.project and release_ = old.name;
  end;


create table ReleaseSetJobs (
    project       text not null,
    -- `release' is a reserved keyword in sqlite >= 3.6.8.  We could
    -- quote them ("release") here, but since the Perl bindings don't
    -- do that it still wouldn't work.  So use `release_' instead.
    release_      text not null,

    job           text not null,

    -- A constraint on the job consisting of `name=value' pairs,
    -- e.g. "system=i686-linux officialRelease=true".  Should really
    -- be a separate table but I'm lazy.
    attrs         text not null,

    -- If set, this is the primary job for the release.  There can be
    -- onlyt one such job per release set.
    isPrimary     integer not null default 0,
    
    mayFail       integer not null default 0,

    description   text,
    
    jobset        text not null,
    
    primary key   (project, release_, job, attrs),
    foreign key   (project) references Projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, release_) references ReleaseSets(project, name) on delete cascade -- ignored by sqlite
    foreign key   (project, jobset) references Jobsets(project, name) on delete restrict -- ignored by sqlite
);


-- Some indices.
create index IndexBuildInputsByBuild on BuildInputs(build);
create index IndexBuildInputsByDependency on BuildInputs(dependency);
