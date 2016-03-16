drop index IndexBuildsOnJobFinishedId;
create index IndexBuildsOnJobFinishedId on builds(project, jobset, job, system, finished, id DESC) where finished = 0;
