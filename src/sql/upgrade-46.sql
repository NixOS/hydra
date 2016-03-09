-- Unify Builds and BuildSteps status codes.
update BuildSteps set status = 3 where status = 4;

-- Get rid of obsolete status code 5.
update Builds set isCachedBuild = 1, buildStatus = 2 where buildStatus = 5;
