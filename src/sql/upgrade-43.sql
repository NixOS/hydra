alter table Builds drop column busy, drop column locker, drop column logfile;

drop index IndexBuildsOnFinishedBusy;
