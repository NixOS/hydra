package Hydra::View::FileStream;

use strict;
use warnings;
use base 'Catalyst::View';
use File::Basename;
use File::Type;
use File::stat;

__PACKAGE__->config(
    'expose_filename' => 1,
);

sub process {
    my ( $self, $c ) = @_;

    my $file_path = $c->stash->{file_path};

    unless ( $file_path && -f $file_path && -r _ ) {
        $c->log->error("File not found or not readable: $file_path");
        $c->res->status(404);
        $c->res->body('File not found');
        return;
    }

    # Determine the MIME type of the file
    my $ft = File::Type->new();
    my $mime_type = $ft->mime_type($file_path) || 'application/octet-stream';

    # Get the file size for the Content-Length header
    my $file_size = ( stat $file_path )[7];

    # Set the response headers
    $c->res->headers->content_type($mime_type);
    $c->res->headers->header( 'Content-Length' => $file_size );

    if ( $self->config->{expose_filename} ) {
        my $filename = basename($file_path);
        $c->res->headers->header( 'Content-Disposition' => "attachment; filename=\"$filename\"" );
    }

    # Open the file and set the filehandle as the response body for streaming
    if ( open my $fh, '<:raw', $file_path ) {
        $c->res->body($fh);
    }
    else {
        $c->log->error("Could not open file: $!");
        $c->res->status(500);
        $c->res->body('Internal Server Error');
    }
}

1;
