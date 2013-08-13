create table AggregateMembers (
    aggregate     integer not null references Builds(id) on delete cascade,
    member        integer not null references Builds(id) on delete cascade,
    primary key   (aggregate, member)
);
