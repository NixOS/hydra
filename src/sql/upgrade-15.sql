-- Previously we didn't always set stoptime.  For those builds, set
-- stoptime to timestamp, since back then timestamp was the time the
-- build finished (for finished builds).
update builds set stoptime = timestamp where finished = 1 and (stoptime is null or stoptime = 0);

-- Idem for starttime.
update builds set starttime = timestamp where finished = 1 and (starttime is null or starttime = 0);

alter table builds add check (finished = 0 or (stoptime is not null and stoptime != 0));
alter table builds add check (finished = 0 or (starttime is not null and starttime != 0));
