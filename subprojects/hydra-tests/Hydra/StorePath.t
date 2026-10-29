use strict;
use warnings;
use Test2::V0;

use Hydra::StorePath;
use Nix::StorePath;

# The store directory is a parameter, so none of this needs a store to exist.
my $storeDir = "/nix/store";
my $base = "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bar";

subtest "a store path is the bare name, and prints back to a full path" => sub {
    my $storePath = parseStorePath($storeDir, "/nix/store/$base");
    is("$storePath", $base, "stringifies to the bare store path");
    is($storePath->to_string, $base, "to_string gives the bare store path");
    is(printStorePath($storeDir, $storePath), "/nix/store/$base", "prints back to the full path");
};

subtest "it is a reference" => sub {
    # Not cosmetic: DBIx::Class::Row::set_inflated_columns only routes a value
    # through a column's deflator when it is a reference. Were this a plain
    # string, `create({drvpath => $storePath})` would write the bare store path
    # into a column that the rest of Hydra -- and the Rust half, which parses
    # these columns with `store_dir.parse` -- reads as a full path.
    my $storePath = parseStorePath($storeDir, "/nix/store/$base");
    ok(ref($storePath), "so that DBIx::Class deflates it on write");
    isa_ok($storePath, ['Nix::StorePath'], "is a Nix::StorePath");
};

subtest "it still behaves like a string where that is wanted" => sub {
    my $storePath = parseStorePath($storeDir, "/nix/store/$base");
    ok($storePath eq $base, "compares equal to its bare name");
    my %seen;
    $seen{$storePath} = 1;
    is([keys %seen], [$base], "works as a hash key");
};

subtest "bad input is rejected" => sub {
    like(dies { parseStorePath($storeDir, "/tmp/elsewhere") }, qr{not in the Nix store},
        "a path outside the store");
    like(dies { parseStorePath($storeDir, "/nix/store/$base/share/doc") }, qr{underneath a store path},
        "a path below a store path");
    like(dies { Nix::StorePath->new("$base/sub") }, qr{must not contain},
        "a bare name containing a slash");
    like(dies { Nix::StorePath->new("") }, qr{must not be empty}, "an empty name");
};

subtest "a relative store path is a pair" => sub {
    my ($storePath, $subPath) =
        parseRelativeStorePath($storeDir, "/nix/store/$base/share/doc/index.html");
    is($storePath->to_string, $base, "the store path");
    is($subPath, "share/doc/index.html", "the sub-path");
    is(printRelativeStorePath($storeDir, $storePath, $subPath),
        "/nix/store/$base/share/doc/index.html", "round-trips");

    my ($exact, $empty) = parseRelativeStorePath($storeDir, "/nix/store/$base");
    is($empty, "", "a path naming a store path exactly has an empty sub-path");
    is(printRelativeStorePath($storeDir, $exact, $empty), "/nix/store/$base",
        "and round-trips too");
};

done_testing;
