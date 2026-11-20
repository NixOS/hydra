package Hydra::Helper::RequestParams;

# Request parameters, decoded against a declared type per name.
#
# A request body can be JSON, so a parameter can arrive as any structure,
# and DBIx::Class reads a hash or a list as query structure rather than as
# data. So handlers do not read request parameters directly: they declare
# the type of each one they use, and get back only those, checked.
#
# A missing or null parameter is undef without being checked, since undef
# is always data, except for a type that coerces it, like `Flag`.
# Parameters that are not declared are left out, with a warning in the log,
# since a client sending more than a handler reads is not an error. The
# result's keys are locked, so a handler reading a name it did not declare
# (a typo, say) dies rather than getting undef.

use utf8;
use strict;
use warnings;
use JSON::MaybeXS ();
use Hash::Util qw(lock_ref_keys);
use Type::Library -base, -declare => qw(Flag MaybeFlag Strings Integer);
use Type::Utils -all;
use Types::Standard qw(Str Undef Item ArrayRef HashRef Int Enum InstanceOf);
use Hydra::Helper::CatalystUtils qw(badRequest trim);
use Hydra::ExternalLink;

# Type::Library exports the types (`Flag`, `MaybeFlag`, `Strings`,
# `Integer`); this adds the functions.
our @EXPORT_OK = qw(requestParams matching oneOf positiveInteger record mapOf externalLink);

# An on/off setting: a JSON boolean, `1` or `0`, or a form checkbox (`on`,
# or absent). Always 1 or 0. Any other string is read by Perl truthiness, so
# that `"false"` means on, which is deprecated: `requestParams` warns about it.
declare Flag, as Item, where { defined $_ && !ref $_ && ($_ eq '1' || $_ eq '0') };
coerce Flag,
    from Undef, via { 0 },
    from Str, via { $_ ? 1 : 0 },
    from Item, via { JSON::MaybeXS::is_bool($_) ? ($_ ? 1 : 0) : $_ };

# Like `Flag`, but a missing value stays undef, for a setting that can come
# from either of two parameters.
declare MaybeFlag, as Flag;
coerce MaybeFlag,
    from Str, via { $_ ? 1 : 0 },
    from Item, via { JSON::MaybeXS::is_bool($_) ? ($_ ? 1 : 0) : $_ };

# The spellings of a flag that are not deprecated, besides JSON booleans.
my %canonicalFlags = map { $_ => 1 } ("", "0", "1", "on");

# A list of strings, such as a group of form checkboxes sharing a name. A
# form sends one value as a plain string, which becomes a one-element list.
declare Strings, as ArrayRef[Str];
coerce Strings,
    from Str, via { [$_] };

# An integer, from a JSON number or a form field, with surrounding spaces
# allowed. A JSON boolean counts as 1 or 0, but is deprecated: `requestParams`
# warns about it.
declare Integer, as Int;
coerce Integer,
    from Str, via { trim($_) },
    from Item, via { JSON::MaybeXS::is_bool($_) ? ($_ ? 1 : 0) : $_ };

# Coerces `$value` to `$type`, if it can. A missing value only if the type
# says what that means, like `Flag` and required fields do.
sub _coerce {
    my ($type, $value) = @_;
    return $value unless $type->has_coercion;
    return $value unless defined $value || $type->coercion->has_coercion_for_type(Undef);
    return $type->coerce($value);
}

# The types below refuse a bad value with `$message`, a string or a function
# of the value in `$_`, rather than a generic one, so that the client sees
# what is wrong with it. A missing value is shown as empty.
sub _message {
    my ($message) = @_;
    # An empty one would make for an empty error, which Catalyst ignores.
    die "a request parameter type needs a message\n" unless ref $message || length($message // "");
    return sub { $message } unless ref $message;
    return sub { local $_ = $_ // ""; $message->() };
}

# A string that `$re` matches in full, once trimmed. A missing or empty
# value is undef, unless `required`, in which case it is refused too.
sub matching {
    my ($re, $message, %opts) = @_;
    return Type::Tiny->new(
        # Not `StrMatch`, which would match against undef, with a warning.
        parent => Str,
        constraint => sub { /\A(?:$re)\z/ },
        message => _message($message),
        coercion => $opts{required}
            ? [ Undef, sub { "" }, Str, sub { trim($_) } ]
            : [ Str, sub { my $s = trim($_); $s eq "" ? undef : $s } ],
    );
}

# One of `@$values`, as a string or a number.
sub oneOf {
    my ($values, $message) = @_;
    return Integer->create_child_type(
        constraint => sub { my $v = $_; grep { $v eq $_ } @$values },
        message => _message($message),
        coercion => 1,
    ) if !grep { !/\A-?\d+\z/ } @$values;
    return Type::Tiny->new(
        parent => Enum[@$values],
        message => _message($message),
        coercion => [ Str, sub { trim($_) } ],
    );
}

# An integer greater than zero.
sub positiveInteger {
    my ($message) = @_;
    return Integer->create_child_type(
        constraint => sub { $_ > 0 },
        message => _message($message),
        coercion => 1,
    );
}

# A link to elsewhere on the web, parsed into a `Hydra::ExternalLink`, of
# which only an `Accepted` one passes. An empty one is undef.
sub externalLink {
    my ($message) = @_;
    return Type::Tiny->new(
        parent => InstanceOf['Hydra::ExternalLink::Accepted'],
        message => _message($message),
        coercion => [ Str, sub { Hydra::ExternalLink->parse($_) } ],
    );
}

# The message for a value that fails `$type`, which `$what` names if the type
# has no message of its own.
sub _messageFor {
    my ($type, $value, $what) = @_;
    return $type->has_message ? $type->get_message($value) : "Invalid $what.";
}

# An object with the fields in `$required`, and optionally those in
# `$optional`, both hashes from name to type. Other fields are kept, unread.
# A bad value is refused with the message of the first field that fails.
sub record {
    my (%opts) = @_;
    my $required = $opts{required} // {};
    my %fields = (%{$opts{optional} // {}}, %$required);
    my $fieldFails = sub {
        my ($h, $name) = @_;
        my $value = $h->{$name};
        return exists $required->{$name} if !defined $value;
        return !$fields{$name}->check($value);
    };
    return Type::Tiny->new(
        constraint => sub {
            my $h = $_;
            return ref $h eq 'HASH' && !grep { $fieldFails->($h, $_) } keys %fields;
        },
        message => sub {
            my $h = $_;
            return "Expected an object." unless ref $h eq 'HASH';
            foreach my $name (sort keys %fields) {
                return _messageFor($fields{$name}, $h->{$name}, "field '$name'") if $fieldFails->($h, $name);
            }
        },
        coercion => [ HashRef, sub {
            my $h = $_;
            return { %$h, map {
                my $type = $fields{$_};
                ($_ => _coerce($type, $h->{$_}));
            } grep { exists $h->{$_} || exists $required->{$_} } keys %fields };
        } ],
    );
}

# An object from names that `$key` accepts to values that `$value` does. A
# bad one is refused with the message of the first name or value that fails.
sub mapOf {
    my ($key, $value) = @_;
    my $entryFails = sub {
        my ($h, $name) = @_;
        return !$key->check($name) || !$value->check($h->{$name});
    };
    return Type::Tiny->new(
        constraint => sub {
            my $h = $_;
            return ref $h eq 'HASH' && !grep { $entryFails->($h, $_) } keys %$h;
        },
        message => sub {
            my $h = $_;
            return "Expected an object." unless ref $h eq 'HASH';
            foreach my $name (sort keys %$h) {
                return _messageFor($key, $name, "name '$name'") unless $key->check($name);
                return _messageFor($value, $h->{$name}, "value for '$name'") unless $value->check($h->{$name});
            }
        },
        coercion => [ HashRef, sub {
            my $h = $_;
            return { map { ($_ => _coerce($value, $h->{$_})) } keys %$h };
        } ],
    );
}

# Returns a hash of the parameters named in `$spec`, a hash from name to
# Type::Tiny type. Refuses the request with 400 if one does not match its
# type. Options:
#
# - `from`: the hash to decode, by default the request's JSON body if it has
#   one, otherwise its query and form parameters.
# - `quiet`: don't warn about undeclared parameters, for a source such as a
#   webhook payload where most of them are expected to go unread.
# - `defaults`: values for parameters that are missing or null, checked like
#   any other, such as a name that otherwise comes from the URL.
# - `ignore`: names not to warn about, though undeclared, such as the
#   read-only fields of what a GET returns, which a client may send back.
sub requestParams {
    my ($c, $spec, %opts) = @_;
    my $path = $c->req->path;
    # The one place that reads the request raw, to parse it.
    ## no critic (Hydra::ProhibitRawRequestParams)
    my $params = $opts{from} // do {
        my $data = $c->request->data;
        if (defined $data && ref $data eq 'HASH' && !%$data && %{$c->request->params}) {
            $c->log->warn("Deprecated: an empty JSON body for $path, whose parameters are read from the query string"
                . " instead; send them in the body.");
        }
        (defined $data && (ref $data ne 'HASH' || %$data)) ? $data : $c->request->params;
    };
    ## use critic
    badRequest($c, "The request parameters must be a JSON object.") unless ref $params eq 'HASH';

    my %ignore = map { $_ => 1 } @{$opts{ignore} // []};
    my @unknown = grep { !exists $spec->{$_} && !$ignore{$_} } sort keys %$params;
    $c->log->warn("Ignoring undeclared request parameters for $path: " . join(", ", @unknown))
        if @unknown && !$opts{quiet};

    my %result;
    foreach my $name (sort keys %$spec) {
        my $type = $spec->{$name};
        my $value = $params->{$name} // $opts{defaults}->{$name};
        $c->log->warn("Deprecated: a JSON boolean for the number parameter '$name' of $path; send 0 or 1 instead.")
            if JSON::MaybeXS::is_bool($value) && $type->is_a_type_of(Integer);
        $c->log->warn("Deprecated: ‘$value’ for the flag '$name' of $path, which is read as "
            . ($value ? "on" : "off") . "; send true or false instead.")
            if defined $value && !ref $value && !$canonicalFlags{$value} && $type->is_a_type_of(Flag);
        $value = _coerce($type, $value);
        if (!defined $value) {
            $result{$name} = undef;
            next;
        }
        unless ($type->check($value)) {
            badRequest($c, $type->get_message($value)) if $type->has_message;
            badRequest($c, "Invalid value for parameter '$name': expected " . $type->display_name . ".");
        }
        $result{$name} = $value;
    }
    lock_ref_keys(\%result);
    return \%result;
}

1;
