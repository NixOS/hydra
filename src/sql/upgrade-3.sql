create index IndexBuildsOnKeep on Builds(keep); -- used by hydra-update-gc-roots
create index IndexMostRecentSuccessfulBuilds on Builds(project, jobset, job, system, finished, buildStatus, id desc); -- used by hydra-update-gc-roots
