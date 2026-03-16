create table CachedDarcsInputs (
    uri           text not null,
    revision      text not null,
    sha256hash    text not null,
    storePath     text not null,
    revCount      integer not null,
    primary key   (uri, revision)
);
