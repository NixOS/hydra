-- Events processed by hydra-notify which have failed at least once
--
-- The payload field contains the original, unparsed payload.
--
-- One row is created for each plugin which fails to process the event,
-- with an increasing retry_at and attempts field.
create table TaskRetries (
    id            serial primary key not null,
    channel       text not null,
    pluginname    text not null,
    payload       text not null,
    attempts      integer not null,
    retry_at      integer not null
);
create index IndexTaskRetriesOrdered on TaskRetries(retry_at asc);
