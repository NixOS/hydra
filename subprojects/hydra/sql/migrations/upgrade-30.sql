drop index IndexBuildStepsOnBusy;
drop index IndexBuildStepsOnDrvpathTypeBusyStatus;
drop index IndexBuildsOnFinished;
drop index IndexBuildsOnFinishedBusy;
drop index IndexBuildsOnIsCurrent;
drop index IndexBuildsOnJobsetIsCurrent;
drop index IndexBuildsOnJobIsCurrent;
drop index IndexBuildsOnKeep;

create index IndexBuildStepsOnBusy on BuildSteps(busy) where busy = 1;
create index IndexBuildStepsOnDrvPath on BuildSteps(drvpath);
create index IndexBuildsOnFinished on Builds(finished) where finished = 0;
create index IndexBuildsOnFinishedBusy on Builds(finished, busy) where finished = 0;
create index IndexBuildsOnIsCurrent on Builds(isCurrent) where isCurrent = 1;
create index IndexBuildsOnJobsetIsCurrent on Builds(project, jobset, isCurrent) where isCurrent = 1;
create index IndexBuildsOnJobIsCurrent on Builds(project, jobset, job, isCurrent) where isCurrent = 1;
create index IndexBuildsOnKeep on Builds(keep) where keep = 1;
