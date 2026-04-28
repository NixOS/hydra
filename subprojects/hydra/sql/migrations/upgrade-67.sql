alter table Builds drop constraint builds_project_fkey2;
alter table BuildMetrics drop constraint buildmetrics_project_fkey2;
alter table StarredJobs drop constraint starredjobs_project_fkey2;
drop table Jobs;
