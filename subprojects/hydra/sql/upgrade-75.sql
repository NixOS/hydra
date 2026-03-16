-- These take about 9 minutes in total on a replica of hydra.nixos.org

create index IndexBuildsJobsetIdCurrentUnfinished on Builds(jobset_id) where isCurrent = 1 and finished = 0;
create index IndexBuildsJobsetIdCurrentFinishedStatus on Builds(jobset_id, buildstatus) where isCurrent = 1 and finished = 1;
create index IndexBuildsJobsetIdCurrent on Builds(jobset_id) where isCurrent = 1;
