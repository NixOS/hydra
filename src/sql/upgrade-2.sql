alter table Builds
    add column priority integer not null default 0,
    add column busy integer not null default 0,
    add column locker text,
    add column logfile text,
    add column disabled integer not null default 0,
    add column startTime integer;

--alter table Builds
--    add column isCachedBuild integer,
--    add column buildStatus integer,
--    add column errorMsg text;

update Builds b set 
    priority = (select priority from BuildSchedulingInfo s where s.id = b.id),
    busy = (select busy from BuildSchedulingInfo s where s.id = b.id),
    disabled = (select disabled from BuildSchedulingInfo s where s.id = b.id),
    locker = (select locker from BuildSchedulingInfo s where s.id = b.id),
    logfile = (select logfile from BuildSchedulingInfo s where s.id = b.id)
    where exists (select 1 from BuildSchedulingInfo s where s.id = b.id);

update Builds b set 
    startTime = ((select startTime from BuildSchedulingInfo s where s.id = b.id) union (select startTime from BuildResultInfo r where r.id = b.id));
--    isCachedBuild = (select isCachedBuild from BuildResultInfo r where r.id = b.id),
--    buildStatus = (select buildStatus from BuildResultInfo r where r.id = b.id),
--    errorMsg = (select errorMsg from BuildResultInfo r where r.id = b.id);
