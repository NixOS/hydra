create index IndexJobsetEvalMembersOnEval on JobsetEvalMembers(eval);

-- Inputs of jobset evals.
create table JobsetEvalInputs (
    eval          integer not null references JobsetEvals(id) on delete cascade,
    name          text not null,
    altNr         integer not null,

    -- Copied from the jobsetinputs from which the build was created.
    type          text not null,
    uri           text,
    revision      text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,

    sha256hash    text,

    primary key   (eval, name, altNr),
    foreign key   (dependency) references Builds(id)
);

-- Reconstruct the repository inputs for pre-existing evals.  This is
-- tricky (and not entirely possible) because builds are not uniquely
-- part of a single eval, so they may have different inputs.

-- For Subversion or Bazaar inputs, pick the highest revision for each
-- input.
insert into JobsetEvalInputs (eval, name, altNr, type, uri, revision)
    select e.id, b.name, 0, max(b.type), max(b.uri), max(b.revision)
    from (select id from JobsetEvals where hasNewBuilds = 1) e
    join JobsetEvalMembers m on e.id = m.eval
    join BuildInputs b on b.build = m.build
    where (b.type = 'svn' or b.type = 'svn-checkout' or b.type = 'bzr' or b.type = 'bzr-checkout')
    group by e.id, b.name
    having count(distinct type) = 1 and count(distinct uri) = 1;

-- For other inputs there is no "best" revision to pick, so only do
-- the conversion if there is only one.
insert into JobsetEvalInputs (eval, name, altNr, type, uri, revision)
    select e.id, b.name, 0, max(b.type), max(uri), max(revision)
    from (select id from JobsetEvals where hasNewBuilds = 1) e
    join JobsetEvalMembers m on e.id = m.eval
    join BuildInputs b on b.build = m.build
    where (b.type != 'svn' and b.type != 'svn-checkout' and b.type != 'bzr' and b.type != 'bzr-checkout')
          and b.uri is not null and b.revision is not null
          and not exists(select 1 from JobsetEvalInputs i where e.id = i.eval and b.name = i.name)
    group by e.id, b.name
    having count(distinct type) = 1 and count(distinct uri) = 1 and count(distinct revision) = 1;
