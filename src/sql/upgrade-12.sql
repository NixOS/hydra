#ifdef POSTGRESQL
alter table builds drop constraint builds_project_fkey;
alter table builds add constraint builds_project_fkey foreign key (project) references Projects(name) on update cascade on delete cascade;
alter table builds drop constraint builds_project_fkey1;
alter table builds add constraint builds_project_fkey1 foreign key (project, jobset) references jobsets(project, name) on update cascade on delete cascade;
#endif

#ifdef SQLITE
alter table Builds rename to Builds2;

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

    -- Information about scheduled builds.
    priority      integer not null default 0,

    busy          integer not null default 0, -- true means someone is building this job now
    locker        text, -- !!! hostname/pid of the process building this job?

    logfile       text, -- if busy, the path of the logfile

    disabled      integer not null default 0, -- !!! boolean

    startTime     integer, -- if busy, time we started
    stopTime      integer,

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

    foreign key   (project) references Projects(name) on update cascade on delete cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade on delete cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade
);

insert into Builds select * from Builds2;

drop table Builds2;

#endif
