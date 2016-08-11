package Hydra::Helper::Properties;

use utf8;
use strict;
use Exporter;
use Hydra::Helper::CatalystUtils qw(error);

our @ISA = qw(Exporter);
our @EXPORT = qw(validateProperties);


sub validateProperty {
    my ($c, $name, $typeDesc, $spec, $value) = @_;

    my $type = exists $spec->{type} ? $spec->{type} : "string";

    if (exists $spec->{properties}) {
        validateProperties($c, $name, $typeDesc, $value->{children}, $spec);
        $value = $value->{value};
    }

    if ($type eq "bool") {
        error($c, "The value ‘$value’ of input ‘$name’ is not a Boolean "
                . "(‘true’ or ‘false’).")
            unless $value eq "1" || $value eq "0";
    } elsif ($type eq "int") {
        error($c, "The value ‘$value’ of input ‘$name’ is not an Integer.")
            unless $value =~ /^\d+$/;
    } elsif ($type eq "attrset") {
        error($c, "The value ‘$value’ of input ‘$name’ is not an Attribute "
                . "Set. (‘{key1: \"value1\", key2: \"value2\"}’)")
            if grep { ref($value->{$_}) eq "" } keys %$value;
    } else {
        error($c, "The value ‘$value’ of input ‘$name’ is not a String.")
            unless ref($value) eq "";
    }

    if (exists $spec->{validate}) {
        $spec->{validate}->($c, $name, $value);
    }
}


sub validateProperties {
    my ($c, $name, $type, $properties, $spec) = @_;

    error($c, "Invalid input type ‘$type’ for input ‘$name’.")
        unless exists $c->stash->{inputTypes}->{$type};

    $spec ||= $c->stash->{inputTypes}->{$type};
    my $typeDesc = $spec->{name} // $type;

    if ($spec->{singleton}) {
        validateProperty($c, $name, $typeDesc, $spec->{singleton},
                         $properties->{value});
    } else {
        my $definedKeys = { %$properties };
        foreach my $key (keys %{$spec->{properties}}) {
            if (exists $properties->{$key}) {
                delete $definedKeys->{$key};
            } else {
                error($c, "Property ‘$key’ is mandatory for input ‘$name’"
                        . " and type ‘$typeDesc’.")
                    if $spec->{properties}->{$key}->{required};
                next;
            }

            validateProperty($c, $name, $type, $spec->{properties}->{$key},
                             $properties->{$key});
        }

        foreach my $key (keys %$definedKeys) {
            error($c, "Property ‘$key’ doesn't exist for input ‘$name’"
                    . " and type ‘$typeDesc’.");
        }
    }
}


1;
