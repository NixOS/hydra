use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Controller::User;

# Address formats we accept, including the subaddressed ones IdPs hand out.
my @valid = (
    'bert@localhost',
    'bert.smith@localhost',
    'bert-smith@localhost',
    'bert_smith@localhost',
    'bert@localhost.localdomain',
    'bert@sub.domain.example',
    'bert+ci@localhost',
    '1234+bert@users.noreply.github.com',
    'bert+ci.smith_more-x@sub.domain.example',
    # A `+` is allowed at either end of the local part.
    '+bert@localhost',
    'bert+@localhost',
    # A domain with a dash in it.
    'bert@ex-ample.com',
    # Length limits are inclusive (RFC 5321).
    ('a' x 64) . '@localhost',
    'b@' . ('a' x 63) . '.' . ('b' x 63) . '.' . ('c' x 63) . '.' . ('d' x 59),
    'b@' . ('a' x 63) . '.' . ('b' x 63) . '.' . ('c' x 63) . '.' . ('d' x 60),
);

my @invalid = (
    '',
    'bert',
    'bert@',
    '@localhost',
    'bert@@localhost',
    'bert@localhost@localhost',
    'bert localhost@localhost',
    'bert@local host',
    'bert+ci@local host',
    'bert@localhost,mallory@localhost',
    'bert@localhost;rm -rf /',
    'Bert <bert@localhost>',
    # Characters that do not survive a round trip through a URL path segment are
    # rejected, since usernames end up in URLs.
    'bert%41x@localhost',
    'bert!smith@localhost',
    'bert&smith@localhost',
    'bert=smith@localhost',
    'bert?smith@localhost',
    'bert/smith@localhost',
    'bert#smith@localhost',
    # Dot-atoms may not start, end or double up on dots.
    '.bert@localhost',
    'bert.@localhost',
    'ber..t@localhost',
    'bert+ci.@localhost',
    # DNS labels may not start or end with a dash, or be empty.
    'bert@-localhost',
    'bert@localhost-',
    'bert@local..host',
    'bert@.localhost',
    'bert@localhost.',
    'bert@local_host',
    'bert@localhost:8080',
    # A trailing newline must not sneak past the end of the pattern.
    "bert\@localhost\n",
    "bert+ci\@localhost\n",
    "bert\@localhost\nX-Injected: 1",
    # Length limits: 64 octets in the local part, 253 in the domain, 254 in
    # total (RFC 5321).
    ('a' x 65) . '@localhost',
    'bert@' . ('a' x 250) . '.example',
    ('a' x 60) . '+' . ('b' x 60) . '@localhost',
);

subtest "valid_email_address" => sub {
    foreach my $address (@valid) {
        ok(Hydra::Controller::User::valid_email_address($address),
            "'$address' is a valid address");
    }
};

subtest "valid_email_address rejects malformed addresses" => sub {
    foreach my $address (@invalid) {
        ok(!Hydra::Controller::User::valid_email_address($address),
            "'$address' is not a valid address");
    }

    ok(!Hydra::Controller::User::valid_email_address(undef),
        "an undefined address is not valid");
};

done_testing;
