create function fail_on_old_pgsql_version() returns boolean as $$
declare
    human_ver text;
    machine_ver integer;
begin
    select setting into machine_ver
        from pg_settings where name = 'server_version_num';
    if machine_ver < 90400 then
        select setting into human_ver
            from pg_settings where name = 'server_version';
        raise exception using message = 'You need at least PostgreSQL version'
                                     || ' 9.4 in order to upgrade to the new'
                                     || ' Hydra schema version. Unfortunately'
                                     || ' you are running version '
                                     || human_ver || ' right now. Please'
                                     || ' update your PostgreSQL server.';
    end if;
    return null;
end;
$$ language plpgsql;

select fail_on_old_pgsql_version();
drop function fail_on_old_pgsql_version();

-- This is a version of "parseJobName" from src/lib/Hydra/Helper/AddBuilds.pm,
-- which used an overly complicated regular expression to parse the string into
-- its components (a bit restructured/annotated to make it easier to read):
--
--   /^ (?: (?:
--    (
--      # project name:
--      (?:[A-Za-z_][A-Za-z0-9-_]*)
--    ) : )? (
--      # jobset name:
--      (?:[A-Za-z_][A-Za-z0-9-_\.]*)
--    ) : )? (
--      # job name:
--      (?:(?:[A-Za-z_][A-Za-z0-9-_]*)(?:\\.(?:[A-Za-z_][A-Za-z0-9-_]*))*)
--    ) \s*
--      (\[ \s* (
--        ([\w]+) (?{ $key = $^N; }) \s* = \s* \"
--        ([\w\-]+) (?{ $attrs{$key} = $^N; }) \"
--      \s* )* \])?
--    $
--   /x
--
-- The original description of "parseJobName" was:
--
--   Parse a job specification of the form `<project>:<jobset>:<job>
--   [attrs]'.  The project, jobset and attrs may be omitted.  The
--   attrs have the form `name = "value"'.
--
-- Fortunately, we only need to take care of valid specifications and we
-- thankfully no longer need to put the results into a string again but
-- rather into a JSONB object.
--
-- So to simplify, first a few observations:
--
--  * We have : as a separator between the fields within <project>,
--    <jobset> and <job>, there are no : allowed.
--  * The [attrs] value starts with a '[', and it isn't allowed in
--    <project>, <jobset> and <job> either.
--  * Fortunately, the attribute keys and values don't allow '"' or '['
--    either.
--
-- This observation allows us to match very strictly solely on the basis
-- of the mentioned delimiters.
create function parse_jobname(value text) returns jsonb as $$
declare
    attrs_raw text[];
    attrs_regex text;
    attrs jsonb;

    spec_raw text[];
    spec_parts text[];
    spec jsonb;
begin
    spec_raw := regexp_matches(value, E'^\\s*([^[]+)');
    attrs_raw := regexp_matches(value, E'\\[(.*)\\]\\s*$');
    attrs_regex := E'\\s*([^=]+?)\\s*=\\s*"([^"]+)"';

    spec_parts := regexp_split_to_array(spec_raw[1], E'\\s*:\\s*');
    case array_length(spec_parts, 1)
        -- Could be more beautiful but this is less error-prone:
        when 1 then spec := jsonb_build_object('job',     spec_parts[1]);
        when 2 then spec := jsonb_build_object('jobset',  spec_parts[1],
                                               'job',     spec_parts[2]);
        when 3 then spec := jsonb_build_object('project', spec_parts[1],
                                               'jobset',  spec_parts[2],
                                               'job',     spec_parts[3]);
        else raise exception 'Unable to parse job name "%".', value;
    end case;

    if array_length(attrs_raw, 1) > 0 then
        select jsonb_object_agg(m[1], m[2]) into attrs
        from regexp_matches(attrs_raw[1], attrs_regex, 'g') as m;
        if attrs is not null then
            spec := spec || jsonb_build_object('attrs', attrs);
        end if;
    end if;

    return spec;
end;
$$ language plpgsql;

-- Just decompose the stringly typed values for the SCM types.
-- This is very hacky and always converts the last argument to boolean.
-- Sole reason for this is to support the deepClone argument for Git types.
create function unscm(value text, n1 text, n2 text) returns jsonb as $$
declare
    fields text[];
    result jsonb;
begin
    fields := regexp_split_to_array(value, ' ');
    result := jsonb_build_object('uri', fields[1]);
    if array_length(fields, 1) > 1 then
        result := result || jsonb_build_object(n1, fields[2]);
    end if;
    if array_length(fields, 1) > 2 and n2 is not null then
        result := result || jsonb_build_object(n2, char_length(fields[3]) > 0);
    end if;
    return result;
end;
$$ language plpgsql;

-- Yes, this function can be done inline as well, but in PL/pgSQL we can use
-- multiple case matches in one single line.
create function migrate_jobset_alts(type text, val text) returns jsonb as $$
begin
    case type
        when 'boolean' then return json_build_object('value', val::boolean);
        when 'build', 'sysbuild' then return parse_jobname(val);
        when 'bzr', 'bzr-checkout' then return jsonb_build_object('uri', val);
        when 'darcs' then return jsonb_build_object('uri', val);
        when 'eval' then return jsonb_build_object('number', val::integer);
        when 'git' then return unscm(val, 'branch', 'deepClone');
        when 'hg' then return unscm(val, 'id', null);
        when 'string' then return json_build_object('value', val);
        when 'nix', 'path' then return json_build_object('value', val);
        when 'svn', 'svn-checkout' then return unscm(val, 'revision', null);
        else raise warning 'Unknown jobset type "%", treating "%" as text.',
                           type, val;
             return json_build_object('value', val);
    end case;
end;
$$ language plpgsql;

alter table jobset_inputs add column properties jsonb null;

update jobset_inputs j set properties = (
    select migrate_jobset_alts(i.type, a.value)
    from jobset_inputs i
    left join jobset_input_alts a on i.name = a.input
                                 and i.project = a.project
                                 and i.jobset = a.jobset
    where i.project = j.project
      and i.jobset = j.jobset
      and i.name = j.name
      and alt_nr = 0
);

drop table jobset_input_alts;

alter table jobset_inputs alter column properties set not null;

drop function migrate_jobset_alts(text, text);
drop function unscm(text, text, text);
drop function parse_jobname(text);
