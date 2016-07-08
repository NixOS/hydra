-- Original schema without any of the statements in upgrade-*.sql applied.

-- This is without comments and unnecessary newlines and it's ONLY for checking
-- whether the upgrade-*.sql files lead to the same result as in hydra.sql.

-- If you want to make modifications to the database schema, please do it by
-- adding a new update-N.sql where N is the biggest number of existing Ns + 1.

-- And for anyone who's just been too lazy to read the above text, simply:

                ----.------------------------------.----
             -------|   DO NOT MODIFY THIS FILE!   |-------
                ----`------------------------------'----
                  --     :                    :     --
                    -- ::--..._    ..    _...--:: --
                      ---( nOpe )  ::  ( nOpe )---
                       --.''''''  :||:  ``````.--
                        ---.      :||:      .---
                          ---.    /  \    .---
                           ---`  `----'  '---
                           ---: _.-..-._ :---
                             --| vvvvvv |--
                             --|/^^^^^^\|--


create table SchemaVersion (
    version         integer not null
);

insert into SchemaVersion (version) values (1);

create table Users (
    userName        text primary key not null,
    fullName        text,
    emailAddress    text not null,
    password        text not null,
    emailOnError    integer not null default 0
);

create table UserRoles (
    userName        text not null,
    role            text not null,
    primary key     (userName, role),
    foreign key     (userName)
                        references Users(userName)
                        on delete cascade on update cascade
);

create table Projects (
    name            text primary key not null,
    displayName     text not null,
    description     text,
    enabled         integer not null default 1,
    hidden          integer not null default 0,
    owner           text not null,
    homepage        text,
    foreign key     (owner)
                        references Users(userName)
                        on update cascade
);

create table ProjectMembers (
    project         text not null,
    userName        text not null,
    primary key     (project, userName),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade,
    foreign key     (userName)
                        references Users(userName)
                        on delete cascade on update cascade
);

create table Jobsets (
    name            text not null,
    project         text not null,
    description     text,
    nixExprInput    text not null,
    nixExprPath     text not null,
    errorMsg        text,
    errorTime       integer,
    lastCheckedTime integer,
    enabled         integer not null default 1,
    enableEmail     integer not null default 1,
    hidden          integer not null default 0,
    emailOverride   text not null,
    keepnr          integer not null default 3,
    primary key     (project, name),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade
);

create table JobsetInputs (
    project         text not null,
    jobset          text not null,
    name            text not null,
    type            text not null,
    primary key     (project, jobset, name),
    foreign key     (project, jobset)
                        references Jobsets(project, name)
                        on delete cascade on update cascade
);

create table JobsetInputAlts (
    project         text not null,
    jobset          text not null,
    input           text not null,
    altnr           integer not null,
    value           text,
    revision        text,
    tag             text,
    primary key     (project, jobset, input, altnr),
    foreign key     (project, jobset, input)
                        references JobsetInputs(project, jobset, name)
                        on delete cascade on update cascade
);

create table Jobs (
    project         text not null,
    jobset          text not null,
    name            text not null,
    active          integer not null default 1,
    errorMsg        text,
    firstEvalTime   integer,
    lastEvalTime    integer,
    disabled        integer not null default 0,
    primary key     (project, jobset, name),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade,
    foreign key     (project, jobset)
                        references Jobsets(project, name)
                        on delete cascade on update cascade
);

create table Builds (
    id              serial primary key not null,
    finished        integer not null,
    timestamp       integer not null,
    project         text not null,
    jobset          text not null,
    job             text not null,
    nixName         text,
    description     text,
    drvPath         text not null,
    outPath         text not null,
    system          text not null,
    longDescription text,
    license         text,
    homepage        text,
    maintainers     text,
    maxsilent       integer default 3600,
    timeout         integer default 36000,
    isCurrent       integer default 0,
    nixExprInput    text,
    nixExprPath     text,
    foreign key     (project)
                        references Projects(name)
                        on update cascade,
    foreign key     (project, jobset)
                        references Jobsets(project, name)
                        on update cascade,
    foreign key     (project, jobset, job)
                        references Jobs(project, jobset, name)
                        on update cascade
);

create table BuildSchedulingInfo (
    id              integer primary key not null,
    priority        integer not null default 0,
    busy            integer not null default 0,
    locker          text not null default '',
    logfile         text,
    disabled        integer not null default 0,
    startTime       integer,
    foreign key     (id)
                        references Builds(id)
                        on delete cascade
);

create table BuildResultInfo (
    id              integer primary key not null,
    isCachedBuild   integer not null,
    buildStatus     integer,
    errorMsg        text,
    startTime       integer,
    stopTime        integer,
    logfile         text,
    logsize         bigint not null default 0,
    size            bigint not null default 0,
    closuresize     bigint not null default 0,
    releaseName     text,
    keep            integer not null default 0,
    failedDepBuild  integer,
    failedDepStepNr integer,
    foreign key     (id)
                        references Builds(id)
                        on delete cascade
);

create table BuildSteps (
    build           integer not null,
    stepnr          integer not null,
    type            integer not null,
    drvPath         text,
    outPath         text,
    logfile         text,
    busy            integer not null,
    status          integer,
    errorMsg        text,
    startTime       integer,
    stopTime        integer,
    machine         text not null default '',
    system          text,
    primary key     (build, stepnr),
    foreign key     (build)
                        references Builds(id)
                        on delete cascade
);

create table BuildInputs (
    id              serial primary key not null,
    build           integer,
    name            text not null,
    type            text not null,
    uri             text,
    revision        text,
    tag             text,
    value           text,
    dependency      integer,
    path            text,
    sha256hash      text,
    foreign key     (build)
                        references Builds(id)
                        on delete cascade,
    foreign key     (dependency)
                        references Builds(id)
);

create table BuildProducts (
    build           integer not null,
    productnr       integer not null,
    type            text not null,
    subtype         text not null,
    fileSize        bigint,
    sha1hash        text,
    sha256hash      text,
    path            text,
    name            text not null,
    description     text,
    defaultPath     text,
    primary key     (build, productnr),
    foreign key     (build)
                        references Builds(id)
                        on delete cascade
);

create table CachedPathInputs (
    srcPath         text not null,
    timestamp       integer not null,
    lastSeen        integer not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (srcPath, sha256hash)
);

create table CachedSubversionInputs (
    uri             text not null,
    revision        integer not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (uri, revision)
);

create table CachedBazaarInputs (
    uri             text not null,
    revision        integer not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (uri, revision)
);

create table CachedGitInputs (
    uri             text not null,
    branch          text not null,
    revision        text not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (uri, branch, revision)
);

create table CachedHgInputs (
    uri             text not null,
    branch          text not null,
    revision        text not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (uri, branch, revision)
);

create table CachedCVSInputs (
    uri             text not null,
    module          text not null,
    timestamp       integer not null,
    lastSeen        integer not null,
    sha256hash      text not null,
    storePath       text not null,
    primary key     (uri, module, sha256hash)
);

create table SystemTypes (
    system          text primary key not null,
    maxConcurrent   integer not null default 2
);

create table Views (
    project         text not null,
    name            text not null,
    description     text,
    keep            integer not null default 0,
    primary key     (project, name),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade
);

create table ViewJobs (
    project         text not null,
    view_           text not null,
    job             text not null,
    attrs           text not null,
    isPrimary       integer not null default 0,
    description     text,
    jobset          text not null,
    autoRelease     integer not null default 0,
    primary key     (project, view_, job, attrs),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade,
    foreign key     (project, view_)
                        references Views(project, name)
                        on delete cascade on update cascade
);

create table Releases (
    project         text not null,
    name            text not null,
    timestamp       integer not null,
    description     text,
    primary key     (project, name),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade
);

create table ReleaseMembers (
    project         text not null,
    release_        text not null,
    build           integer not null,
    description     text,
    primary key     (project, release_, build),
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade,
    foreign key     (project, release_)
                        references Releases(project, name)
                        on delete cascade on update cascade,
    foreign key     (build)
                        references Builds(id)
);

create table JobsetEvals (
    id              serial primary key not null,
    project         text not null,
    jobset          text not null,
    timestamp       integer not null,
    checkoutTime    integer not null,
    evalTime        integer not null,
    hasNewBuilds    integer not null,
    hash            text not null,
    foreign key     (project)
                        references Projects(name)
                        on delete cascade on update cascade,
    foreign key     (project, jobset)
                        references Jobsets(project, name)
                        on delete cascade on update cascade
);

create table JobsetEvalMembers (
    eval            integer not null
                        references JobsetEvals(id)
                        on delete cascade,
    build           integer not null
                        references Builds(id)
                        on delete cascade,
    isNew           integer not null,
    primary key     (eval, build)
);

create table UriRevMapper (
    baseuri         text not null,
    uri             text not null,
    primary key     (baseuri)
);

create table NewsItems (
    id              serial primary key not null,
    contents        text not null,
    createTime      integer not null,
    author          text not null,
    foreign key     (author)
                        references Users(userName)
                        on delete cascade on update cascade
);

create table BuildMachines (
    hostname        text primary key not null,
    username        text default '' not null,
    ssh_key         text default '' not null,
    options         text default '' not null,
    maxconcurrent   integer default 2 not null,
    speedfactor     integer default 1 not null,
    enabled         integer default 0 not null
);

create table BuildMachineSystemTypes (
    hostname        text not null,
    system          text not null,
    primary key     (hostname, system),
    foreign key     (hostname)
                        references BuildMachines(hostname)
                        on delete cascade
);

create index IndexBuildInputsOnBuild
          on BuildInputs(build);
create index IndexBuildInputsOnDependency
          on BuildInputs(dependency);
create index IndexBuildProducstOnBuildAndType
          on BuildProducts(build, type);
create index IndexBuildProductsOnBuild
          on BuildProducts(build);
create index IndexBuildSchedulingInfoOnBuild
          on BuildSchedulingInfo(id);
create index IndexBuildStepsOnBuild
          on BuildSteps(build);
create index IndexBuildStepsOnDrvpathTypeBusyStatus
          on BuildSteps(drvpath, type, busy, status);
create index IndexBuildStepsOnOutpath
          on BuildSteps(outpath);
create index IndexBuildStepsOnOutpathBuild
          on BuildSteps (outpath, build);
create index IndexBuildsOnFinished
          on Builds(finished);
create index IndexBuildsOnIsCurrent
          on Builds(isCurrent);
create index IndexBuildsOnJobsetIsCurrent
          on Builds(project, jobset, isCurrent);
create index IndexBuildsOnJobIsCurrent
          on Builds(project, jobset, job, isCurrent);
create index IndexBuildsOnJobAndSystem
          on Builds(project, jobset, job, system);
create index IndexBuildsOnJobset
          on Builds(project, jobset);
create index IndexBuildsOnProject
          on Builds(project);
create index IndexBuildsOnTimestamp
          on Builds(timestamp);
create index IndexBuildsOnJobsetFinishedTimestamp
          on Builds(project, jobset, finished, timestamp DESC);
create index IndexBuildsOnJobFinishedId
          on builds(project, jobset, job, system, finished, id DESC);
create index IndexBuildsOnJobSystemCurrent
          on Builds(project, jobset, job, system, isCurrent);
create index IndexBuildsOnDrvPath
          on Builds(drvPath);
create index IndexCachedHgInputsOnHash
          on CachedHgInputs(uri, branch, sha256hash);
create index IndexCachedGitInputsOnHash
          on CachedGitInputs(uri, branch, sha256hash);
create index IndexCachedSubversionInputsOnUriRevision
          on CachedSubversionInputs(uri, revision);
create index IndexCachedBazaarInputsOnUriRevision
          on CachedBazaarInputs(uri, revision);
create index IndexJobsetEvalMembersOnBuild
          on JobsetEvalMembers(build);
create index IndexJobsetInputAltsOnInput
          on JobsetInputAlts(project, jobset, input);
create index IndexJobsetInputAltsOnJobset
          on JobsetInputAlts(project, jobset);
create index IndexProjectsOnEnabled
          on Projects(enabled);
create index IndexReleaseMembersOnBuild
          on ReleaseMembers(build);
