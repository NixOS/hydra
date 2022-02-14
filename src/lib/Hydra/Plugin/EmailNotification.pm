package Hydra::Plugin::EmailNotification;

use utf8;
use strict;
use warnings;
use parent 'Hydra::Plugin';
use POSIX qw(strftime);
use Template;
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Email;

sub isEnabled {
    my ($self) = @_;
    return ($self->{config}->{email_notification} // 0) == 1;
}

my $template = <<EOF;
Hi,

The status of Hydra job ‘[% showJobName(build) %]’ [% IF showSystem %](on [% build.system %]) [% END %][% IF prevBuild && build.buildstatus != prevBuild.buildstatus %]has changed from "[% showStatus(prevBuild) %]" to "[% showStatus(build) %]"[% ELSE %]is "[% showStatus(build) %]"[% END %].  For details, see

  [% baseurl %]/build/[% build.id %]

[% IF dependents.size > 0 -%]
The following dependent jobs also failed:

[% FOREACH b IN dependents -%]
* [% showJobName(b) %] ([% baseurl %]/build/[% b.id %])
[% END -%]

[% END -%]
[% IF nrCommits > 0 && authorList -%]
This may be due to [% IF nrCommits > 1 -%][% nrCommits %] commits[%- ELSE -%]a commit[%- END -%] by [% authorList %].

[% END -%]
[% IF build.buildstatus == 0 -%]
Yay!
[% ELSE -%]
Go forth and fix [% IF dependents.size == 0 -%]it[% ELSE %]them[% END %].
[% END -%]

Regards,

The Hydra build daemon.
EOF

sub buildFinished {
    my ($self, $topbuild, $dependents) = @_;

    die unless $topbuild->finished;

    # Figure out to whom to send notification for each build.  For
    # each email address, we send one aggregate email listing only the
    # relevant builds for that address.
    my %addresses;
    foreach my $build ($topbuild, @{$dependents}) {
        my $prevBuild = getPreviousBuild($build);

        # Do we want to send mail for this build?
        unless ($ENV{'HYDRA_FORCE_SEND_MAIL'}) {
            next unless $build->jobset->enableemail;

            # If build is cancelled or aborted, do not send email.
            next if $build->buildstatus == 4 || $build->buildstatus == 3;

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send email.
            next if defined $prevBuild && ($build->buildstatus == $prevBuild->buildstatus);
        }

        my $to = $build->jobset->emailoverride ne "" ? $build->jobset->emailoverride : $build->maintainers;

        foreach my $address (split ",", ($to // "")) {
            $address = trim $address;

            $addresses{$address} //= { builds => [] };
            push @{ $addresses{$address}->{builds} }, $build;
        }
    }

    my ($authors, $nrCommits, $emailable_authors) = getResponsibleAuthors($topbuild, $self->{plugins});
    my $authorList;
    my $prevBuild = getPreviousBuild($topbuild);
    if (scalar keys %{$authors} > 0
        && ((!defined $prevBuild) || ($topbuild->buildstatus != $prevBuild->buildstatus)))
    {
        my @x = map { "$_ <$authors->{$_}>" } (sort keys %{$authors});
        $authorList = join(" or ", scalar @x > 1 ? join(", ", @x[ 0 .. scalar @x - 2 ]) : (), $x[-1]);
        $addresses{$_} = { builds => [$topbuild] } foreach (@{$emailable_authors});
    }

    # Send an email to each interested address.
    for my $to (keys %addresses) {
        print STDERR "sending mail notification to ", $to, "\n";
        my @builds = @{ $addresses{$to}->{builds} };

        my $tt = Template->new({});

        my $vars = {
            build       => $topbuild,
            prevBuild   => getPreviousBuild($topbuild),
            dependents  => [ grep { $_->id != $topbuild->id } @builds ],
            baseurl     => getBaseUrl($self->{config}),
            showJobName => \&showJobName,
            showStatus  => \&showStatus,
            showSystem  => index($topbuild->get_column('job'), $topbuild->system) == -1,
            nrCommits   => $nrCommits,
            authorList  => $authorList
        };

        my $body;
        $tt->process(\$template, $vars, \$body)
          or die "failed to generate email from template";

        # stripping trailing spaces from lines
        $body =~ s/[\ ]+$//gm;

        my $subject =
            showStatus($topbuild)
          . ": Hydra job "
          . showJobName($topbuild)
          . ($vars->{showSystem}                 ? " on " . $topbuild->system                              : "")
          . (scalar @{ $vars->{dependents} } > 0 ? " (and " . scalar @{ $vars->{dependents} } . " others)" : "");

        sendEmail(
            $self->{config},
            $to, $subject, $body,
            [
                'X-Hydra-Project' => $topbuild->jobset->get_column('project'),
                'X-Hydra-Jobset'  => $topbuild->jobset->get_column('name'),
                'X-Hydra-Job'     => $topbuild->get_column('job'),
                'X-Hydra-System'  => $topbuild->system
            ]
        );
    }
}

1;
