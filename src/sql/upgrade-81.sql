alter table runcommandlogs add column uuid uuid;
update runcommandlogs set uuid = gen_random_uuid() where uuid is null;
alter table runcommandlogs alter column uuid set not null;
alter table runcommandlogs add constraint RunCommandLogs_uuid_unique unique(uuid);
# the unique uuid constraint adds a unique, btree index, so we don't need to create out own:
#    "runcommandlogs_uuid_unique" UNIQUE CONSTRAINT, btree (uuid)
