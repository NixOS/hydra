alter table JobsetEvals
    add column nrBuilds integer,
    add column nrSucceeded integer;

update JobsetEvals e set
    nrBuilds = (select count(*) from JobsetEvalMembers m where e.id = m.eval)
    where hasNewBuilds = 1;
