ALTER TABLE Jobsets
    ADD COLUMN enable_dynamic_run_command boolean not null default false;
ALTER TABLE Projects
    ADD COLUMN enable_dynamic_run_command boolean not null default false;
