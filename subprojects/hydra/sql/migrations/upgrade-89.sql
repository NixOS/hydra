CREATE INDEX IndexBuildsOnJobsetIdJobStopTimeId ON Builds(jobset_id, job, stoptime DESC, id DESC) WHERE finished = 1;
