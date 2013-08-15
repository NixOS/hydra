create table AggregateConstituents (
    aggregate     integer not null references Builds(id) on delete cascade,
    constituent   integer not null references Builds(id) on delete cascade,
    primary key   (aggregate, constituent)
);
