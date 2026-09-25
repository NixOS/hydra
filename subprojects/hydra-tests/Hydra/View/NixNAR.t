use strict;
use warnings;
use Setup;

use Hydra::View::NixNAR;

use Test2::V0;

subtest "numCompressThreads" => sub {
    is(Hydra::View::NixNAR::numCompressThreads({}), 0,
        "unset option means no explicit thread count");

    is(Hydra::View::NixNAR::numCompressThreads({ compress_num_threads => 4 }), 4,
        "a single declaration is used as-is");

    is(Hydra::View::NixNAR::numCompressThreads({ compress_num_threads => [ 0, 4 ] }), 4,
        "the last declaration wins when the option is declared twice");

    is(Hydra::View::NixNAR::numCompressThreads({ compress_num_threads => "banana" }), 0,
        "non-numeric values are dropped rather than spliced into the shell command");
};

done_testing;
