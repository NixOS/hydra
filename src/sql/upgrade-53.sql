alter table projects add column declprops jsonb;

update projects
    set declprops = migrate_jobset_alts(decltype, declvalue)
    where decltype is not null;

alter table projects drop column declvalue;

update projects
    set decltype = 'buildnr',
        declprops = jsonb_build_object('value', declprops->>'job')
    where decltype = 'build'
      and declprops->>'job' ~ '^\d+$';

drop function migrate_jobset_alts(text, text);
drop function unscm(text, text, text);
drop function parse_jobname(text);
