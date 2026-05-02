package Nix::Store;

use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
    StoreWrapper
    StoreWrapper::new
    StoreWrapper::isValidPath StoreWrapper::queryReferences StoreWrapper::queryPathInfo StoreWrapper::queryDeriver StoreWrapper::queryPathHash
    StoreWrapper::queryPathFromHashPart
    StoreWrapper::topoSortPaths StoreWrapper::computeFSClosure followLinksToStorePath StoreWrapper::exportPaths StoreWrapper::importPaths
    StoreWrapper::addToStore StoreWrapper::makeFixedOutputPath
    StoreWrapper::derivationFromPath
    StoreWrapper::addTempRoot
    StoreWrapper::queryRawRealisation

    hashPath hashFile hashString convertHash
    signString checkSignature
    getStoreDir
    setVerbosity
);

our $VERSION = '0.15';

sub backtick {
    open(my $fh, "-|", @_) or die;
    local $/;
    my $res = <$fh> || "";
    close $fh or die;
    return $res;
}

require XSLoader;
XSLoader::load('Nix::Store', $VERSION);

1;
__END__
