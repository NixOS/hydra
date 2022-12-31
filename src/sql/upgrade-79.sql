-- Records of RunCommand executions
--
-- The intended flow is:
--
-- 1. Create a RunCommandLogs entry when the task is "queued" to run
-- 2. Update the start_time when it begins
-- 3. Update the end_time and exit_code when it completes
create table RunCommandLogs (
    id            serial primary key not null,
    job_matcher   text not null,
    build_id      integer not null,
    -- TODO: evaluation_id integer not null,
    -- can we do this in a principled way? a build can be part of many evaluations
    -- but a "bug" of RunCommand, imho, is that it should probably run per evaluation?
    command         text not null,
    start_time      integer,
    end_time        integer,
    error_number    integer,
    exit_code       integer,
    signal          integer,
    core_dumped     boolean,

    foreign key (build_id) references Builds(id) on delete cascade,
    -- foreign key (evaluation_id) references Builds(id) on delete cascade,


    constraint RunCommandLogs_not_started_no_exit_time_no_code check (
        -- If start time is null, then end_time, exit_code, signal, and core_dumped should be null.
        -- A logical implication operator would be nice :).
        (start_time is not null) or (
            end_time is null
            and error_number is null
            and exit_code is null
            and signal is null
            and core_dumped is null
        )
    ),
    constraint RunCommandLogs_end_time_has_start_time check (
        -- If end time is not null, then end_time, exit_code, and core_dumped should not be null
        (end_time is null) or (start_time is not null)
    )

    -- Note: if exit_code is not null then signal and core_dumped must be null.
    -- Similarly, if signal is not null then exit_code must be null and
    -- core_dumped must not be null. However, these semantics are tricky
    -- to encode as constraints and probably provide limited actual value.
);
