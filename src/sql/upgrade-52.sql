update jobset_inputs
    set type = 'buildnr',
        properties = jsonb_build_object('value', properties->>'job')
    where type = 'build'
      and properties->>'job' ~ '^\d+$';
