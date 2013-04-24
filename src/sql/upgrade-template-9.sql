create table BuildOutputs (
    build         integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, name),
    foreign key   (build) references Builds(id) on delete cascade
);

insert into BuildOutputs (build, name, path)
    select id, 'out', outPath from Builds;

alter table Builds drop column outPath;

create table BuildStepOutputs (
    build         integer not null,
    stepnr        integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, stepnr, name),
    foreign key   (build) references Builds(id) on delete cascade,
    foreign key   (build, stepnr) references BuildSteps(build, stepnr) on delete cascade
);

insert into BuildStepOutputs (build, stepnr, name, path)
    select build, stepnr, 'out', outPath from BuildSteps where outPath is not null;

drop index IndexBuildStepsOnBuild;
drop index IndexBuildStepsOnOutpath;
drop index IndexBuildStepsOnOutpathBuild;

alter table BuildSteps drop column outPath;

create index IndexBuildStepOutputsOnPath on BuildStepOutputs(path);
