package Hydra::View::NixExprs;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;


sub process {
    my ($self, $c) = @_;

    my $res = "[\n";

    foreach my $name (keys %{$c->stash->{nixPkgs}}) {
        my $build = $c->stash->{nixPkgs}->{$name};
        $res .= "  # $name\n";
        $res .= "  { type = \"derivation\";\n";
        $res .= "    name = \"" . ($build->resultInfo->releasename or $build->nixname) . "\";\n"; # !!! escaping?
        $res .= "    system = \"" . $build->system . "\";\n"; # idem
        $res .= "    outPath = " . $build->outpath . ";\n";
        $res .= "    meta = {\n";
        $res .= "      description = \"" . $build->description . "\";\n"
            if $build->description;
        $res .= "      longDescription = \"" . $build->longdescription . "\";\n"
            if $build->longdescription;
        $res .= "      license = \"" . $build->license . "\";\n"
            if $build->license;
        $res .= "    };\n";
        $res .= "  }\n";
    }

    $res .= "]\n";
    
    $c->response->content_type('text/plain');
    $c->response->body($res);

    return 1;
}


1;
