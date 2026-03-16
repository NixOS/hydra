drop index IndexJobsetEvalsOnJobsetId;
create index IndexJobsetEvalsOnJobsetId on JobsetEvals(project, jobset, id desc) where hasNewBuilds = 1;
