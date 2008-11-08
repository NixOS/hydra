create table builds (
    id            integer primary key autoincrement not null,
    timestamp     integer not null, -- time this build was added to the db (in Unix time)

    -- Info about the inputs.
    project       text not null, -- !!! foreign key
    jobSet        text not null, -- !!! foreign key
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
    system        text not null
);


create table buildInputs (
    buildId       integer not null,
    
    -- Copied from the jobSetInputs from which the build was created.
    name          text not null,
    type          text not null,
    uri           text,
    revision      integer,
    tag           text,
    value         text,
    inputId       integer, -- build ID of the input, for type == 'build'

    path          text,
    
    primary key   (buildId, name),
    foreign key   (buildId) references builds(id) on delete cascade -- ignored by sqlite
    foreign key   (inputId) references builds(id) -- ignored by sqlite
);


create table buildProducts (
    buildId       integer not null,
    path          text not null,
    type          text not null, -- "nix-build", "file", "doc", "report", ...
    subtype       text not null, -- "source-dist", "rpm", ...
    primary key   (buildId, path),
    foreign key   (buildId) references builds(id) on delete cascade -- ignored by sqlite
);


create table buildLogs (
    buildId       integer not null,
    logPhase      text not null,
    path          text not null,
    type          text not null,
    primary key   (buildId, logPhase),
    foreign key   (buildId) references builds(id) on delete cascade -- ignored by sqlite
);


-- Emulate "on delete cascade" foreign key constraints.
create trigger cascadeBuildDeletion
  before delete on builds
  for each row begin
    delete from buildInputs where buildId = old.id;
    delete from buildLogs where buildId = old.id;
    delete from buildProducts where buildId = old.id;
  end;


create table projects (
    name          text primary key not null 
);


-- A jobset consists of a set of inputs (e.g. SVN repositories), one
-- of which contains a Nix expression containing an attribute set
-- describing build jobs.
create table jobSets (
    name          text not null,
    project       text not null,
    description   text,
    nixExprInput  text not null, -- name of the jobSetInput containing the Nix expression
    nixExprPath   text not null, -- relative path of the Nix expression
    primary key   (project, name),
    foreign key   (project) references projects(name) on delete cascade, -- ignored by sqlite
    foreign key   (project, name, nixExprInput) references jobSetInputs(project, job, name)
);


create table jobSetInputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "cvs", "path", "file", "string"
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references jobSets(project, name) on delete cascade -- ignored by sqlite
);


create table jobSetInputAlts (
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
    foreign key   (project, jobset, input) references jobSetInputs(project, jobset, name) on delete cascade -- ignored by sqlite
);


create table jobQueue (
    id            integer primary key autoincrement not null,
    timestamp     integer not null, -- time this build was added to the db (in Unix time)
    
    -- Info about the inputs.
    project       text not null, -- !!! foreign key
    jobSet        text not null, -- !!! foreign key
    attrName      text not null,

    -- What this job will build.
    description   text,
    drvPath       text not null,
    outPath       text not null,
    system        text not null
);
