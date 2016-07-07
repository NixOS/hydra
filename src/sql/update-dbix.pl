make_schema_at("Hydra::Schema", {
    naming => { ALL => "v5" },
    relationships => 1,
    moniker_map => sub {
        return "CachedCVSInputs" if $_ eq "cached_cvs_inputs";
        return "SchemaVersion"   if $_ eq "schemaversion";
        return $_ =~ s/(?:_|^)([a-z])/\u$1/gr;
    },
    components => [ "+Hydra::Component::ToJSON" ],
    rel_name_map => { build_steps_builds => "build_steps" }
}, [$ENV{"HYDRA_DBI"}]);
