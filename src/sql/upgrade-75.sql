create table Maintainers (
    id            serial primary key not null,

    email         text not null unique,
    github_handle text null
);

create table BuildsByMaintainers (
    maintainer_id   integer not null,
    build_id        integer not null,

    primary key (maintainer_id, build_id),
    foreign key (maintainer_id) references Maintainers(id),
    foreign key (build_id) references Builds(id)
);
