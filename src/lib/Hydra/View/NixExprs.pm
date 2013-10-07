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

    my %perSystem;

    foreach my $pkg (@{$c->stash->{nixPkgs}}) {
        my $build = $pkg->{build};
        my $s = "";
        $s .= "  # $pkg->{name}\n";
        $s .= "  ${\escape $build->get_column('job')} = {\n";
        $s .= "    type = \"derivation\";\n";
        $s .= "    name = ${\escape ($build->get_column('releasename') or $build->nixname)};\n";
        $s .= "    system = ${\escape $build->system};\n";
        $s .= "    outPath = ${\escape $pkg->{outPath}};\n";
        $s .= "    meta = {\n";
        $s .= "      description = ${\escape $build->description};\n"
            if $build->description;
        $s .= "      longDescription = ${\escape $build->longdescription};\n"
            if $build->longdescription;
        $s .= "      license = ${\escape $build->license};\n"
            if $build->license;
        $s .= "      maintainers = ${\escape $build->maintainers};\n"
            if $build->maintainers;
        $s .= "    };\n";
        $s .= "  };\n\n";
        $perSystem{$build->system} .= $s;
    }

    my $res = "{ system ? builtins.currentSystem }:\n\n";

    my $first = 1;
    foreach my $system (keys %perSystem) {
        $res .= "else " if !$first;
        $res .= "if system == ${\escape $system} then {\n\n";
        $res .= $perSystem{$system};
        $res .= "}\n\n";
        $first = 0;
    }

    $res .= "else " if !$first;
    $res .= "{}\n";

    my $tar = Archive::Tar->new;
    $tar->add_data("channel/channel-name", ($c->stash->{channelName} or "unnamed-channel"), {mtime => 1});
    $tar->add_data("channel/default.nix", $res, {mtime => 1});

    my $tardata = $tar->write;
    my $bzip2data;
    bzip2(\$tardata => \$bzip2data);

    $c->response->content_type('application/x-bzip2');
    $c->response->body($bzip2data);

    return 1;
}


1;
