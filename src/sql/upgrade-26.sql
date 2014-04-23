create table JobsetRenames (
    project       text not null,
    from_         text not null,
    to_           text not null,
    primary key   (project, from_),
    foreign key   (project) references Projects(name) on delete cascade on update cascade,
    foreign key   (project, to_) references Jobsets(project, name) on delete cascade on update cascade
);
