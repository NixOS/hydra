package Hydra::Helper::AttributeSet;

use strict;
use warnings;

sub new {
    my ($self) = @_;
    return bless { "paths" => [] }, $self;
}

sub registerValue {
    my ($self, $attributePath) = @_;

    my @pathParts = splitPath($attributePath);

    pop(@pathParts);
    if (scalar(@pathParts) == 0) {
        return;
    }

    my $lineage = "";
    for my $pathPart (@pathParts) {
        $lineage = $self->registerChild($lineage, $pathPart);
    }
}

sub registerChild {
    my ($self, $parent, $attributePath) = @_;
    if ($parent ne "") {
        $parent .= "."
    }

    my $name = $parent . $attributePath;
    if (!grep { $_ eq $name} @{$self->{"paths"}}) {
        push(@{$self->{"paths"}}, $name);
    }
    return $name;
}

sub splitPath {
    my ($s) = @_;

    if ($s eq "") {
        return ('')
    }

    return split(/\./, $s, -1);
}

sub enumerate {
    my ($self) = @_;
    my @paths = sort { length($a) <=> length($b) } @{$self->{"paths"}};
    return @paths;
}

1;
