package Hydra::View::NixExprs;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;
use Hydra::Helper::Escape;
use Hydra::Helper::AttributeSet;
use Archive::Tar;
use IO::Compress::Bzip2 qw(bzip2);
use Encode;
use JSON::PP;

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
        $res .= "if system == ${\escapeString $system} then {\n\n";
        my $attrsets = Hydra::Helper::AttributeSet->new();
        foreach my $job (keys %{$perSystem{$system}}) {
            my $pkg = $perSystem{$system}->{$job};
            my $build = $pkg->{build};
            my $attr = $build->get_column('job');
            $attrsets->registerValue($attr);

            $res .= "  # Hydra build ${\$build->id}\n";
            $res .= "  ${\escapeAttributePath $attr} = (mkFakeDerivation {\n";
            $res .= "    type = \"derivation\";\n";
            $res .= "    name = ${\escapeString ($build->get_column('releasename') or $build->nixname)};\n";
            $res .= "    system = ${\escapeString $build->system};\n";
            $res .= "    meta = {\n";
            $res .= "      description = ${\escapeString $build->description};\n"
                if $build->description;
            $res .= "      license = ${\escapeString $build->license};\n"
                if $build->license;
            $res .= "      maintainers = ${\escapeString $build->maintainers};\n"
                if $build->maintainers;
            if ($build->outputstoinstall) {
                $res .= "      outputsToInstall = [ ";
                $res .= join " ", map escape($_), @{decode_json $build->outputstoinstall};
                $res .= "];\n"
            }

            $res .= "    };\n";
            $res .= "  } {\n";
            my @outputNames = sort (keys %{$pkg->{outputs}});
            $res .= "    ${\escapeString $_} = ${\escapeString $pkg->{outputs}->{$_}};\n" foreach @outputNames;
            my $out = defined $pkg->{outputs}->{"out"} ? "out" : $outputNames[0];
            $res .= "  }).$out;\n\n";
        }

        for my $attrset ($attrsets->enumerate()) {
            $res .= "  ${\escapeAttributePath $attrset}.recurseForDerivations = true;\n\n";
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
