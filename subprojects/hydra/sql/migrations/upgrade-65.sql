-- Add an index like IndexBuildsOnJobFinishedId using jobset_id
create index IndexBuildsOnJobsetIdFinishedId on Builds(id DESC, finished, job, jobset_id);
