create table BuildMetrics (
    build         integer not null,
    name          text not null,

    unit          text,
    value         double precision not null,

    -- Denormalisation for performance: copy some columns from the
    -- corresponding build.
    project       text not null,
    jobset        text not null,
    job           text not null,
    timestamp     integer not null,

    primary key   (build, name),
    foreign key   (build) references Builds(id) on delete cascade,
    foreign key   (project) references Projects(name) on update cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade
);

create index IndexBuildMetricsOnJobTimestamp on BuildMetrics(project, jobset, job, timestamp desc);
