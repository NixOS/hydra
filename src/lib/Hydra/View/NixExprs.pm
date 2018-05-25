package Hydra::View::NixExprs;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;
use Archive::Tar;
use IO::Compress::Bzip2 qw(bzip2);
use Encode;


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
        $perSystem{$build->system}->{$build->get_column('job')} = $pkg;
    }

    my $res = <<EOF;
{ system ? builtins.currentSystem }:

let

  maybeStorePath = if builtins ? langVersion && builtins.lessThan 1 builtins.langVersion
    then builtins.storePath
    else x: x;

  mkFakeDerivation = attrs: outputs:
    let
      outputNames = builtins.attrNames outputs;
      common = attrs // outputsSet //
        { type = "derivation";
          outputs = outputNames;
          all = outputsList;
        };
      outputToAttrListElement = outputName:
        { name = outputName;
          value = common // {
            inherit outputName;
            outPath = maybeStorePath (builtins.getAttr outputName outputs);
          };
        };
      outputsList = map outputToAttrListElement outputNames;
      outputsSet = builtins.listToAttrs outputsList;
    in outputsSet;

in

EOF

    my $first = 1;
    foreach my $system (keys %perSystem) {
        $res .= "else " if !$first;
        $res .= "if system == ${\escape $system} then {\n\n";

        foreach my $job (keys %{$perSystem{$system}}) {
            my $pkg = $perSystem{$system}->{$job};
            my $build = $pkg->{build};
            $res .= "  # Hydra build ${\$build->id}\n";
            my $attr = $build->get_column('job');
            $attr =~ s/\./-/g;
            $res .= "  ${\escape $attr} = (mkFakeDerivation {\n";
            $res .= "    type = \"derivation\";\n";
            $res .= "    name = ${\escape ($build->get_column('releasename') or $build->nixname)};\n";
            $res .= "    system = ${\escape $build->system};\n";
            $res .= "    meta = {\n";
            $res .= "      description = ${\escape $build->description};\n"
                if $build->description;
            $res .= "      license = ${\escape $build->license};\n"
                if $build->license;
            $res .= "      maintainers = ${\escape $build->maintainers};\n"
                if $build->maintainers;
            $res .= "    };\n";
            $res .= "  } {\n";
            my @outputNames = sort (keys %{$pkg->{outputs}});
            $res .= "    ${\escape $_} = ${\escape $pkg->{outputs}->{$_}};\n" foreach @outputNames;
            my $out = defined $pkg->{outputs}->{"out"} ? "out" : $outputNames[0];
            $res .= "  }).$out;\n\n";
        }

        $res .= "}\n\n";
        $first = 0;
    }

    $res .= "else " if !$first;
    $res .= "{}\n";

    my $tar = Archive::Tar->new;
    $tar->add_data("channel/channel-name", ($c->stash->{channelName} or "unnamed-channel"), {mtime => 1});
    $tar->add_data("channel/default.nix", encode('utf8',$res), {mtime => 1});

    my $tardata = $tar->write;
    my $bzip2data;
    bzip2(\$tardata => \$bzip2data);

    $c->response->content_type('application/x-bzip2');
    $c->response->body($bzip2data);

    return 1;
}


1;
