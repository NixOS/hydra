alter table BuildSteps
  add column timesBuilt integer,
  add column isNonDeterministic boolean;
