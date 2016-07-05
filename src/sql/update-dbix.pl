make_schema_at("Hydra::Schema", {
    naming => { ALL => "v5" },
    relationships => 1,
    moniker_map => sub {
        return "CachedCVSInputs" if $_ eq "cached_cvs_inputs";
        return $_ =~ s/(?:_|^)([a-z])/\u$1/gr;
    },
    components => [ "+Hydra::Component::ToJSON" ],
    rel_name_map => { buildsteps_builds => "buildsteps" }
}, [$ENV{"HYDRA_DBI"}]);
