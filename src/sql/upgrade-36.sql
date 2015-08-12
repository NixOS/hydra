create index IndexBuildStepsOnPropagatedFrom on BuildSteps(propagatedFrom) where propagatedFrom is not null;
