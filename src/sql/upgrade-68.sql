drop index IndexBuildsOnJobsetIdFinishedId;
create index IndexBuildsOnJobsetIdFinishedId on Builds(jobset_id, job, finished, id DESC);

drop index IndexFinishedSuccessfulBuilds;
create index IndexFinishedSuccessfulBuilds on Builds(jobset_id, job, finished, buildstatus, id DESC) where buildstatus = 0 and finished = 1;
