alter table BuildSteps
  add column propagatedFrom integer,
  add foreign key (propagatedFrom) references Builds(id) on delete cascade;
