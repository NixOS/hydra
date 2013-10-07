alter table Jobsets add column emailResponsible integer not null default 0;
alter table JobsetInputs add column checkResponsible integer not null default 0;
alter table BuildInputs add column checkResponsible integer not null default 0;
