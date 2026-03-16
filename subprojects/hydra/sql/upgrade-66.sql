update Jobsets set type = 0 where type is null;
alter table Jobsets alter column type set not null;
