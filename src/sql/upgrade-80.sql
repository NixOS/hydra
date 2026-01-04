drop index IndexBuildsOnJobsetIsCurrent;
drop index IndexBuildsOnJobIsCurrent;
drop index IndexBuildsOnJobset;
drop index IndexBuildsOnProject;
drop index IndexBuildsOnJobFinishedId;

alter table Builds
    drop column project,
    drop column jobset;
