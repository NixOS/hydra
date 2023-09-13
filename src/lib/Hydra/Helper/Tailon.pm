use File::Basename;

my $inotify = 0;

sub spawnTailon {
    my ($c, $drvPath) = @_;
    my $logfile = getDrvLogPath($drvPath);
    my $socketDir = Hydra::Model::DB::getHydraPath . "/build-logs/";
    my $baseDrv = basename $drvPath;
    my $socket = $socketDir . $baseDrv . ".sock";

    if (-e $socket) {
        return $socket;
    }

    # Start inotify
    if ($inotify == 0) {
        use threads;
        use Linux::Inotify2;

        $inotify = new Linux::Inotify2 or die "unable to create inotify object: $!";
        my $pid = fork();
        if (not $pid and defined $pid) {
            $inotify->poll while 1;
        } elsif (not $pid) {
            die "Cannot fork";
        }
    }

    # Spawn tailon
    unlink($socket);
    my $pid = fork();
    if ($pid eq 0) {
        setpgrp(0, 0);
        umask(0777 - 0666); # Results in 666
        exec($c->config->{tailon_bin}, "-b", $socket, "-r", "/tailon/" . $baseDrv, "alias=" . $baseDrv . "," . $logfile);
        print("Cannot exec tailon: $!\n");
        return;
    } elsif ($pid lt 0) {
        die "Cannot fork";
    } else {
        $inotify->watch($logfile, IN_DELETE_SELF, sub {
            my $e = shift;
            kill($pid);
            unlink($socket);
            # Delete this handler
            $e->w->cancel;
        });
    }

    return $socket;
}

1;
