-- Singleton table to keep track of the schema version.
create table schemaversion (
    version       integer not null
);


create table users (
    username      text primary key not null,
    full_name      text,
    email_address  text not null,
    password      text not null, -- sha256 hash
    email_on_error  integer not null default 0,
    type          text not null default 'hydra', -- either "hydra" or "persona"
    public_dashboard boolean not null default false
);


create table user_roles (
    username      text not null,
    role          text not null,
    primary key   (username, role),
    foreign key   (username) references users(username) on delete cascade on update cascade
);


create table projects (
    name          text primary key not null, -- project id, lowercase (e.g. "patchelf")
    display_name   text not null, -- display name (e.g. "PatchELF")
    description   text,
    enabled       integer not null default 1,
    hidden        integer not null default 0,
    owner         text not null,
    homepage      text, -- URL for the project
    declfile      text, -- File containing declarative jobset specification
    decltype      text, -- Type of the input containing declarative jobset specification
    declvalue     text, -- Value of the input containing declarative jobset specification
    foreign key   (owner) references users(username) on update cascade
);


create table project_members (
    project       text not null,
    username      text not null,
    primary key   (project, username),
    foreign key   (project) references projects(name) on delete cascade on update cascade,
    foreign key   (username) references users(username) on delete cascade on update cascade
);


-- A jobset consists of a set of inputs (e.g. SVN repositories), one
-- of which contains a Nix expression containing an attribute set
-- describing build jobs.
create table jobsets (
    name          text not null,
    project       text not null,
    description   text,
    nix_expr_input  text not null, -- name of the jobsetInput containing the Nix or Guix expression
    nix_expr_path   text not null, -- relative path of the Nix or Guix expression
    error_msg      text, -- used to signal the last evaluation error etc. for this jobset
    error_time     integer, -- timestamp associated with errorMsg
    last_checked_time integer, -- last time the evaluator looked at this jobset
    trigger_time   integer, -- set if we were triggered by a push event
    enabled       integer not null default 1, -- 0 = disabled, 1 = enabled, 2 = one-shot
    enable_email   integer not null default 1,
    hidden        integer not null default 0,
    email_override text not null,
    keepnr        integer not null default 3,
    check_interval integer not null default 300, -- minimum time in seconds between polls (0 = disable polling)
    scheduling_shares integer not null default 100,
    fetch_error_msg text,
    constraint    jobsets_check check (scheduling_shares > 0),
    primary key   (project, name),
    foreign key   (project) references projects(name) on delete cascade on update cascade
);


create function notify_jobset_shares_changed() returns trigger as 'begin notify jobset_shares_changed; return null; end;' language plpgsql;
create trigger jobset_shares_changed after update on jobsets for each row
  when (old.scheduling_shares != new.scheduling_shares) execute procedure notify_jobset_shares_changed();


create table jobset_renames (
    project       text not null,
    from_         text not null,
    to_           text not null,
    primary key   (project, from_),
    foreign key   (project) references projects(name) on delete cascade on update cascade,
    foreign key   (project, to_) references jobsets(project, name) on delete cascade on update cascade
);


create table jobset_inputs (
    project       text not null,
    jobset        text not null,
    name          text not null,
    type          text not null, -- "svn", "path", "uri", "string", "boolean", "nix"
    email_responsible integer not null default 0, -- whether to email committers to this input who change a build
    primary key   (project, jobset, name),
    foreign key   (project, jobset) references jobsets(project, name) on delete cascade on update cascade
);


create table jobset_input_alts (
    project       text not null,
    jobset        text not null,
    input         text not null,
    alt_nr         integer not null,

    -- urgh
    value         text, -- for most types, a URI; for 'path', an absolute path; for 'string', an arbitrary value
    revision      text, -- for repositories

    primary key   (project, jobset, input, alt_nr),
    foreign key   (project, jobset, input) references jobset_inputs(project, jobset, name) on delete cascade on update cascade
);


create table jobs (
    project       text not null,
    jobset        text not null,
    name          text not null,

    primary key   (project, jobset, name),
    foreign key   (project) references projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references jobsets(project, name) on delete cascade on update cascade
);


create table builds (
    id            serial primary key not null,

    finished      integer not null, -- 0 = scheduled, 1 = finished

    timestamp     integer not null, -- time this build was added

    -- Info about the inputs.
    project       text not null,
    jobset        text not null,
    job           text not null,

    -- Info about the build result.
    nix_name       text, -- name attribute of the derivation
    description   text, -- meta.description
    drv_path       text not null,
    system        text not null,

    license       text, -- meta.license
    homepage      text, -- meta.homepage
    maintainers   text, -- meta.maintainers (concatenated, comma-separated)
    maxsilent     integer default 3600, -- meta.maxsilent
    timeout       integer default 36000, -- meta.timeout

    is_channel     integer not null default 0, -- meta.isHydraChannel
    is_current     integer default 0,

    -- Copy of the nixExprInput/nixExprPath fields of the jobset that
    -- instantiated this build.  Needed if we want to reproduce this
    -- build.
    nix_expr_input  text,
    nix_expr_path   text,

    -- Priority within a jobset, set via meta.schedulingPriority.
    priority      integer not null default 0,

    -- Priority among all builds, used by the admin to bump builds to
    -- the front of the queue via the web interface.
    global_priority integer not null default 0,

    -- FIXME: remove startTime?
    start_time     integer, -- if busy/finished, time we started
    stop_time      integer, -- if finished, time we finished

    -- Information about finished builds.
    is_cached_build integer, -- boolean

    -- Status codes used for builds and steps:
    --   0 = succeeded
    --   1 = regular Nix failure (derivation returned non-zero exit code)
    --   2 = build of a dependency failed [builds only]
    --   3 = build or step aborted due to misc failure
    --   4 = build cancelled (removed from queue; never built) [builds only]
    --   5 = [obsolete]
    --   6 = failure with output (i.e. $out/nix-support/failed exists) [builds only]
    --   7 = build timed out
    --   8 = cached failure [steps only; builds use isCachedBuild]
    --   9 = unsupported system type
    --  10 = log limit exceeded
    --  11 = NAR size limit exceeded
    build_status   integer,

    size          bigint,
    closure_size   bigint,

    release_name   text, -- e.g. "patchelf-0.5pre1234"

    keep          integer not null default 0, -- true means never garbage-collect the build output

    check (finished = 0 or (stop_time is not null and stop_time != 0)),
    check (finished = 0 or (start_time is not null and start_time != 0)),

    foreign key   (project) references projects(name) on update cascade,
    foreign key   (project, jobset) references jobsets(project, name) on update cascade,
    foreign key   (project, jobset, job) references jobs(project, jobset, name) on update cascade
);


create function notify_builds_added() returns trigger as 'begin notify builds_added; return null; end;' language plpgsql;
create trigger builds_added after insert on builds execute procedure notify_builds_added();

create function notify_builds_deleted() returns trigger as 'begin notify builds_deleted; return null; end;' language plpgsql;
create trigger builds_deleted after delete on builds execute procedure notify_builds_deleted();

create function notify_build_restarted() returns trigger as 'begin notify builds_restarted; return null; end;' language plpgsql;
create trigger build_restarted after update on builds for each row
  when (old.finished = 1 and new.finished = 0) execute procedure notify_build_restarted();

create function notify_build_cancelled() returns trigger as 'begin notify builds_cancelled; return null; end;' language plpgsql;
create trigger build_cancelled after update on builds for each row
  when (old.finished = 0 and new.finished = 1 and new.build_status = 4) execute procedure notify_build_cancelled();

create function notify_build_bumped() returns trigger as 'begin notify builds_bumped; return null; end;' language plpgsql;
create trigger build_bumped after update on builds for each row
  when (old.global_priority != new.global_priority) execute procedure notify_build_bumped();


create table build_outputs (
    build         integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, name),
    foreign key   (build) references builds(id) on delete cascade
);


-- TODO: normalize this. Currently there can be multiple BuildSteps
-- for a single step.
create table build_steps (
    build         integer not null,
    stepnr        integer not null,

    type          integer not null, -- 0 = build, 1 = substitution

    drv_path       text,

    busy          integer not null,

    status        integer, -- see Builds.buildStatus

    error_msg      text,

    start_time     integer,
    stop_time      integer,

    machine       text not null default '',
    system        text,

    propagated_from integer,

    -- Time in milliseconds spend copying stuff from/to build machines.
    overhead      integer,

    primary key   (build, stepnr),
    foreign key   (build) references builds(id) on delete cascade,
    foreign key   (propagated_from) references builds(id) on delete cascade
);


create table build_step_outputs (
    build         integer not null,
    stepnr        integer not null,
    name          text not null,
    path          text not null,
    primary key   (build, stepnr, name),
    foreign key   (build) references builds(id) on delete cascade,
    foreign key   (build, stepnr) references build_steps(build, stepnr) on delete cascade
);


-- Inputs of builds.
create table build_inputs (
    id            serial primary key not null,

    -- Which build this input belongs to.
    build         integer,

    -- Copied from the jobsetinputs from which the build was created.
    name          text not null,
    type          text not null,
    uri           text,
    revision      text,
    value         text,
    email_responsible integer not null default 0,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,

    sha256hash    text,

    foreign key   (build) references builds(id) on delete cascade,
    foreign key   (dependency) references builds(id)
);


create table build_products (
    build         integer not null,
    productnr     integer not null,
    type          text not null, -- "nix-build", "file", "doc", "report", ...
    subtype       text not null, -- "source-dist", "rpm", ...
    file_size      bigint,
    sha1hash      text,
    sha256hash    text,
    path          text,
    name          text not null, -- generally just the filename part of `path'
    default_path   text, -- if `path' is a directory, the default file relative to `path' to be served
    primary key   (build, productnr),
    foreign key   (build) references builds(id) on delete cascade
);


create table build_metrics (
    build         integer not null,
    name          text not null,

    unit          text,
    value         double precision not null,

    -- Denormalisation for performance: copy some columns from the
    -- corresponding build.
    project       text not null,
    jobset        text not null,
    job           text not null,
    timestamp     integer not null,

    primary key   (build, name),
    foreign key   (build) references builds(id) on delete cascade,
    foreign key   (project) references projects(name) on update cascade,
    foreign key   (project, jobset) references jobsets(project, name) on update cascade,
    foreign key   (project, jobset, job) references jobs(project, jobset, name) on update cascade
);


-- Cache for inputs of type "path" (used for testing Hydra), storing
-- the SHA-256 hash and store path for each source path.  Also stores
-- the timestamp when we first saw the path have these contents, which
-- may be used to generate release names.
create table cached_path_inputs (
    src_path       text not null,
    timestamp     integer not null, -- when we first saw this hash
    last_seen      integer not null, -- when we last saw this hash
    sha256hash    text not null,
    store_path     text not null,
    primary key   (src_path, sha256hash)
);


create table cached_subversion_inputs (
    uri           text not null,
    revision      integer not null,
    sha256hash    text not null,
    store_path     text not null,
    primary key   (uri, revision)
);

create table cached_bazaar_inputs (
    uri           text not null,
    revision      integer not null,
    sha256hash    text not null,
    store_path     text not null,
    primary key   (uri, revision)
);

create table cached_git_inputs (
    uri           text not null,
    branch        text not null,
    revision      text not null,
    sha256hash    text not null,
    store_path     text not null,
    primary key   (uri, branch, revision)
);

create table cached_darcs_inputs (
    uri           text not null,
    revision      text not null,
    sha256hash    text not null,
    store_path     text not null,
    rev_count      integer not null,
    primary key   (uri, revision)
);

create table cached_hg_inputs (
    uri           text not null,
    branch        text not null,
    revision      text not null,
    sha256hash    text not null,
    store_path     text not null,
    primary key   (uri, branch, revision)
);

create table cached_cvs_inputs (
    uri           text not null,
    module        text not null,
    timestamp     integer not null, -- when we first saw this hash
    last_seen      integer not null, -- when we last saw this hash
    sha256hash    text not null,
    store_path     text not null,
    primary key   (uri, module, sha256hash)
);


-- FIXME: remove
create table system_types (
    system        text primary key not null,
    max_concurrent integer not null default 2
);


-- A release is a named set of builds.  The ReleaseMembers table lists
-- the builds that constitute each release.
create table releases (
    project       text not null,
    name          text not null,

    timestamp     integer not null,

    description   text,

    primary key   (project, name),
    foreign key   (project) references projects(name) on delete cascade
);


create table release_members (
    project       text not null,
    release_      text not null,
    build         integer not null,

    description   text,

    primary key   (project, release_, build),
    foreign key   (project) references projects(name) on delete cascade on update cascade,
    foreign key   (project, release_) references releases(project, name) on delete cascade on update cascade,
    foreign key   (build) references builds(id)
);


create table jobset_evals (
    id            serial primary key not null,

    project       text not null,
    jobset        text not null,

    timestamp     integer not null, -- when this entry was added
    checkout_time  integer not null, -- how long obtaining the inputs took (in seconds)
    eval_time      integer not null, -- how long evaluation took (in seconds)

    -- If 0, then the evaluation of this jobset did not cause any new
    -- builds to be added to the database.  Otherwise, *all* the
    -- builds resulting from the evaluation of the jobset (including
    -- existing ones) can be found in the JobsetEvalMembers table.
    has_new_builds  integer not null,

    -- Used to prevent repeated Nix expression evaluation for the same
    -- set of inputs for a jobset.  In the evaluator, after obtaining
    -- the current inputs for a jobset, we hash the inputs together,
    -- and if the resulting hash already appears in this table, we can
    -- skip the jobset.  Otherwise we proceed.  The hash is computed
    -- over the command-line arguments to hydra-eval-jobs.
    hash          text not null,

    -- Cached stats about the builds.
    nr_builds      integer,
    nr_succeeded   integer, -- set lazily when all builds are finished

    foreign key   (project) references projects(name) on delete cascade on update cascade,
    foreign key   (project, jobset) references jobsets(project, name) on delete cascade on update cascade
);


create table jobset_eval_inputs (
    eval          integer not null references jobset_evals(id) on delete cascade,
    name          text not null,
    alt_nr         integer not null,

    -- Copied from the jobsetinputs from which the build was created.
    type          text not null,
    uri           text,
    revision      text,
    value         text,
    dependency    integer, -- build ID of the input, for type == 'build'

    path          text,

    sha256hash    text,

    primary key   (eval, name, alt_nr),
    foreign key   (dependency) references builds(id)
);


create table jobset_eval_members (
    eval          integer not null references jobset_evals(id) on delete cascade,
    build         integer not null references builds(id) on delete cascade,
    is_new         integer not null,
    primary key   (eval, build)
);


create table uri_rev_mapper (
    baseuri       text not null,
    uri           text not null,
    primary key   (baseuri)
);


create table news_items (
    id            serial primary key not null,
    contents      text not null,
    create_time    integer not null,
    author        text not null,
    foreign key   (author) references users(username) on delete cascade on update cascade
);


create table aggregate_constituents (
    aggregate     integer not null references builds(id) on delete cascade,
    constituent   integer not null references builds(id) on delete cascade,
    primary key   (aggregate, constituent)
);


create table starred_jobs (
    username      text not null,
    project       text not null,
    jobset        text not null,
    job           text not null,
    primary key   (username, project, jobset, job),
    foreign key   (username) references users(username) on update cascade on delete cascade,
    foreign key   (project) references projects(name) on update cascade on delete cascade,
    foreign key   (project, jobset) references jobsets(project, name) on update cascade on delete cascade,
    foreign key   (project, jobset, job) references jobs(project, jobset, name) on update cascade on delete cascade
);


-- The output paths that have permanently failed.
create table failed_paths (
    path text primary key not null
);


-- Needed because Postgres doesn't have "ignore duplicate" or upsert
-- yet.
create rule idempotent_insert as on insert to failed_paths
  where exists (select 1 from failed_paths where path = new.path)
  do instead nothing;


create table system_status (
    what text primary key not null,
    status json not null
);


-- Cache of the number of finished builds.
create table nr_builds (
    what  text primary key not null,
    count integer not null
);

insert into nr_builds(what, count) values('finished', 0);


create function modify_nr_builds_finished() returns trigger as $$
  begin
    if ((tg_op = 'INSERT' and new.finished = 1) or
        (tg_op = 'UPDATE' and old.finished = 0 and new.finished = 1)) then
      update nr_builds set count = count + 1 where what = 'finished';
    elsif ((tg_op = 'DELETE' and old.finished = 1) or
           (tg_op = 'UPDATE' and old.finished = 1 and new.finished = 0)) then
      update nr_builds set count = count - 1 where what = 'finished';
    end if;
    return null;
  end;
$$ language plpgsql;

create trigger nr_builds_finished after insert or update or delete on builds
  for each row
  execute procedure modify_nr_builds_finished();


-- Some indices.

create index index_build_inputs_on_build on build_inputs(build);
create index index_build_inputs_on_dependency on build_inputs(dependency);
create index index_build_metrics_on_job_timestamp on build_metrics(project, jobset, job, timestamp desc);
create index index_build_outputs_on_path on build_outputs(path);
create index index_build_producst_on_build_and_type on build_products(build, type);
create index index_build_products_on_build on build_products(build);
create index index_build_steps_on_busy on build_steps(busy) where busy = 1;
create index index_build_steps_on_drv_path on build_steps(drv_path);
create index index_build_steps_on_propagated_from on build_steps(propagated_from) where propagated_from is not null;
create index index_build_steps_on_stop_time on build_steps(stop_time desc) where start_time is not null and stop_time is not null;
create index index_build_step_outputs_on_path on build_step_outputs(path);
create index index_builds_on_finished on builds(finished) where finished = 0;
create index index_builds_on_is_current on builds(is_current) where is_current = 1;
create index index_builds_on_jobset_is_current on builds(project, jobset, is_current) where is_current = 1;
create index index_builds_on_job_is_current on builds(project, jobset, job, is_current) where is_current = 1;
create index index_builds_on_jobset on builds(project, jobset);
create index index_builds_on_project on builds(project);
create index index_builds_on_timestamp on builds(timestamp);
create index index_builds_on_finished_stop_time on builds(finished, stop_time DESC);
create index index_builds_on_job_finished_id on builds(project, jobset, job, system, finished, id DESC);
create index index_builds_on_drv_path on builds(drv_path);
create index index_cached_hg_inputs_on_hash on cached_hg_inputs(uri, branch, sha256hash);
create index index_cached_git_inputs_on_hash on cached_git_inputs(uri, branch, sha256hash);
create index index_cached_subversion_inputs_on_uri_revision on cached_subversion_inputs(uri, revision);
create index index_cached_bazaar_inputs_on_uri_revision on cached_bazaar_inputs(uri, revision);
create index index_jobset_eval_members_on_build on jobset_eval_members(build);
create index index_jobset_eval_members_on_eval on jobset_eval_members(eval);
create index index_jobset_input_alts_on_input on jobset_input_alts(project, jobset, input);
create index index_jobset_input_alts_on_jobset on jobset_input_alts(project, jobset);
create index index_projects_on_enabled on projects(enabled);
create index index_release_members_on_build on release_members(build);

--  For hydra-update-gc-roots.
create index index_builds_on_keep on builds(keep) where keep = 1;

-- To get the most recent eval for a jobset.
create index index_jobset_evals_on_jobset_id on jobset_evals(project, jobset, id desc) where has_new_builds = 1;
