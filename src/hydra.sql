create table builds (
    id            integer primary key autoincrement not null,
    timestamp     integer not null, -- time this build was added to the db (in Unix time)

    -- Info about the inputs.
    project       text not null, -- !!! foreign key
    jobset        text not null, -- !!! foreign key
    attrName      text not null,

    -- Info about the build result.
    description   text,
    drvPath       text not null,
    outPath       text not null,
    isCachedBuild integer not null, -- boolean
    buildStatus   integer, -- 0 = succeeded, 1 = Nix build failure, 2 = positive build failure
    errorMsg      text, -- error message in case of a Nix failure
    startTime     integer, -- in Unix time, 0 = used cached build result
    stopTime      integer,
    system        text not null,

    foreign key   (project) references projects(name), -- ignored by sqlite
    foreign key   (project, jobset) references jobsets(project, name) -- ignored by sqlite
);


-- Inputs of jobs/builds.
create table inputs ( 
    id            integer primary key autoincrement not null,

    -- Which job or build this input belongs to.  Exactly one must be non-null.
    build         integer,
    job           integer,
    
    -- Copied from the jobsetinputs from which the build was created.
    name          text not null,
    type          text not null,
    uri           text,
    revision      integer,
    tag           text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,
    
    foreign key   (build) references builds(id) -- ignored by sqlite
    foreign key   (job) references jobs(id) -- ignored by sqlite
    foreign key   (dependency) references builds(id) -- ignored by sqlite
);


create table buildProducts (
    build         integer not null,
    path          text not null,
    type          text not null, -- "nix-build", "file", "doc", "report", ...
    subtype       text not null, -- "source-dist", "rpm", ...
    primary key   (build, path),
    foreign key   (build) references builds(id) on delete cascade -- ignored by sqlite
);


create table buildLogs (
    build         integer not null,
    logPhase      text not null,
    path          text not null,
    type          text not null,
    primary key   (build, logPhase),
    foreign key   (build) references builds(id) on delete cascade -- ignored by sqlite
);


-- Emulate "on delete cascade" foreign key constraints.
create trigger cascadeBuildDeletion
  before delete on builds
  for each row begin
    --delete from buildInputs where build = old.id;
    delete from buildLogs where build = old.id;
    delete from buildProducts where build = old.id;
  end;


create table projects (
    name          text primary key not null 
);


-- A jobset consists of a set of inputs (e.g. SVN repositories), one
-- of which contains a Nix expression containing an attribute set
-- describing build jobs.
create table jobsets (
    name          text not null,
    project       text not null,
    description   text,
    nixExprInput  text not null, -- name of the jobsetInput containing the Nix expression
    nixExprPath   text not null, -- relative path of the Nix expression
    primary key   (project, name),
    foreign key   (project) references projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, name, nixExprInput) references jobsetInputs(project, job, name)
);


create table jobsetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "cvs", "path", "file", "string"
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references jobsets(project, name) on delete cascade -- ignored by sqlite
);


create table jobsetInputAlts (
    project       text not null,
    jobset        text not null,
    input         text not null,
    altnr         integer,

    -- urgh
    uri           text,
    revision      integer, -- for type == 'svn'
    tag           text, -- for type == 'cvs'
    value         text, -- for type == 'string'
    
    primary key   (project, jobset, input, altnr),
    foreign key   (project, jobset, input) references jobsetInputs(project, jobset, name) on delete cascade -- ignored by sqlite
);


create table jobs (
    id            integer primary key autoincrement not null,
    timestamp     integer not null, -- time this build was added to the db (in Unix time)

    priority      integer not null,

    busy          integer not null, -- true means someone is building this job now
    locker        text not null, -- !!! hostname/pid of the process building this job?
    
    -- Info about the inputs.
    project       text not null, -- !!! foreign key
    jobset        text not null, -- !!! foreign key
    attrName      text not null,

    -- What this job will build.
    description   text,
    drvPath       text not null,
    outPath       text not null,
    system        text not null,

    foreign key   (project) references projects(name), -- ignored by sqlite
    foreign key   (project, jobset) references jobsets(project, name) -- ignored by sqlite
);
