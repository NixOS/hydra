-- Index more exactly what the latest-finished query looks for.
create index IndexFinishedSuccessfulBuilds
  on Builds(id DESC, buildstatus, finished, job, jobset_id)
  where buildstatus = 0 and finished = 1;
