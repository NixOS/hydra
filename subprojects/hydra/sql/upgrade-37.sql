create index IndexBuildStepsOnStopTime on BuildSteps(stopTime desc) where startTime is not null and stopTime is not null;
