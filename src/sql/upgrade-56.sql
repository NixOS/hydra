drop index IndexBuildStepsOnBusy;
create index IndexBuildStepsOnBusy on BuildSteps(busy) where busy != 0;
