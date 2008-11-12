-- This table contains all builds, either scheduled or finished.  For
-- scheduled builds, additional info (such as the priority) can be
-- found in the BuildSchedulingInfo table.  For finished builds,
-- additional info (such as the logs, build products, etc.) can be
-- found in several tables, such as BuildResultInfo, BuildLogs and
-- BuildProducts.
create table Builds (
    id            integer primary key autoincrement not null,

    finished      integer not null, -- 0 = scheduled, 1 = finished
    
    timestamp     integer not null, -- time this build was scheduled / finished building

    -- Info about the inputs.
    project       text not null, -- !!! foreign key
    jobset        text not null, -- !!! foreign key
    attrName      text not null,

    -- Info about the build result.
    nixName       text, -- name attribute of the derivation
    description   text,
    drvPath       text not null,
    outPath       text not null,
    system        text not null,
    
    foreign key   (project) references Projects(name), -- ignored by sqlite
    foreign key   (project, jobset) references Jobsets(project, name) -- ignored by sqlite
);


-- Info for a scheduled build.
create table BuildSchedulingInfo (
    id            integer primary key not null,
    
    priority      integer not null default 0,

    busy          integer not null default 0, -- true means someone is building this job now
    locker        text not null default '', -- !!! hostname/pid of the process building this job?

    logfile       text, -- if busy, the path of the logfile
    
    foreign key   (id) references Builds(id) on delete cascade -- ignored by sqlite
);


-- Info for a finished build.
create table BuildResultInfo (
    id            integer primary key not null,
    
    isCachedBuild integer not null, -- boolean
    
    buildStatus   integer, -- 0 = succeeded, 1 = Nix build failure, 2 = positive build failure

    errorMsg      text, -- error message in case of a Nix failure
    
    startTime     integer, -- in Unix time, 0 = used cached build result
    stopTime      integer,

    foreign key   (id) references Builds(id) on delete cascade -- ignored by sqlite
);


create table BuildSteps (
    id            integer not null,
    stepnr        integer not null,

    type          integer not null, -- 0 = build, 1 = substitution

    drvPath       text, 
    outPath       text,

    logfile       text,

    busy          integer not null,

    status        integer,

    errorMsg      text,

    startTime     integer, -- in Unix time, 0 = used cached build result
    stopTime      integer,

    primary key   (id, stepnr),
    foreign key   (id) references Builds(id) on delete cascade -- ignored by sqlite
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
    primary key   (build, productnr),
    foreign key   (build) references Builds(id) on delete cascade -- ignored by sqlite
);


create table BuildLogs (
    build         integer not null,
    logPhase      text not null,
    path          text not null,
    type          text not null,
    primary key   (build, logPhase),
    foreign key   (build) references Builds(id) on delete cascade -- ignored by sqlite
);


-- Emulate "on delete cascade" foreign key constraints.
create trigger cascadeBuildDeletion
  before delete on builds
  for each row begin
    delete from BuildSchedulingInfo where id = old.id;
    delete from BuildResultInfo where id = old.id;
    delete from BuildInputs where build = old.id;
    delete from BuildLogs where build = old.id;
    delete from BuildProducts where build = old.id;
  end;


create table Projects (
    name          text primary key not null, -- project id, lowercase (e.g. "patchelf")
    displayName   text not null, -- display name (e.g. "PatchELF")
    description   text
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
    primary key   (project, name),
    foreign key   (project) references Projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, name, nixExprInput) references JobsetInputs(project, job, name)
);


create table JobsetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "cvs", "path", "file", "string"
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references Jobsets(project, name) on delete cascade -- ignored by sqlite
);


create table JobsetInputAlts (
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
    foreign key   (project, jobset, input) references JobsetInputs(project, jobset, name) on delete cascade -- ignored by sqlite
);
