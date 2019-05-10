alter table Jobsets alter column nixExprInput drop not null;
alter table Jobsets alter column nixExprPath drop not null;
alter table Jobsets add column type integer default 0;
alter table Jobsets add column flake text;
alter table Jobsets add check ((type = 0) = (nixExprInput is not null and nixExprPath is not null));
alter table Jobsets add check ((type = 1) = (flake is not null));
