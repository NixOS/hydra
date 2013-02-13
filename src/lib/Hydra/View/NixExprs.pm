package Hydra::View::NixExprs;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;
use Archive::Tar;
use IO::Compress::Bzip2 qw(bzip2);


sub escape {
    my ($s) = @_;
    $s =~ s|\\|\\\\|g;
    $s =~ s|\"|\\\"|g;
    $s =~ s|\$|\\\$|g;
    return "\"" . $s . "\"";
}


sub process {
    my ($self, $c) = @_;

    my $res = "[\n";

    foreach my $pkg (@{$c->stash->{nixPkgs}}) {
        my $build = $pkg->{build};
        $res .= "  # $pkg->{name}\n";
        $res .= "  { type = \"derivation\";\n";
        $res .= "    name = " . escape ($build->get_column("releasename") or $build->nixname) . ";\n";
        $res .= "    system = " . (escape $build->system) . ";\n";
        $res .= "    outPath = " . (escape $pkg->{outPath}) . ";\n";
        $res .= "    meta = {\n";
        $res .= "      description = " . (escape $build->description) . ";\n"
            if $build->description;
        $res .= "      longDescription = " . (escape $build->longdescription) . ";\n"
            if $build->longdescription;
        $res .= "      license = " . (escape $build->license) . ";\n"
            if $build->license;
        $res .= "    };\n";
        $res .= "  }\n";
    }

    $res .= "]\n";

    my $tar = Archive::Tar->new;
    $tar->add_data("channel/channel-name", ($c->stash->{channelName} or "unnamed-channel"), {mtime => 0});
    $tar->add_data("channel/default.nix", $res, {mtime => 0});

    my $tardata = $tar->write;
    my $bzip2data;
    bzip2(\$tardata => \$bzip2data);

    $c->response->content_type('application/x-bzip2');
    $c->response->body($bzip2data);

    return 1;
}


1;
