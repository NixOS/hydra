#ifdef POSTGRESQL
alter table builds drop constraint builds_project_fkey;
alter table builds add constraint builds_project_fkey foreign key (project) references Projects(name) on update cascade on delete cascade;
alter table builds drop constraint builds_project_fkey1;
alter table builds add constraint builds_project_fkey1 foreign key (project, jobset) references jobsets(project, name) on update cascade on delete cascade;
#endif
