use strict;
use warnings;

package KanidmContext;

use LWP::UserAgent;
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX qw(SIGTERM WNOHANG);
use Data::Dumper;
use URI;

# Starts a new Kanidm process with a temporary database, a random port, and an oauth client for
# Hydra to use.
sub new {
    my ($class, %opts) = @_;

    # CLEANUP => 0, yath will delete the directory.
    my $kanidm_dir = $opts{'kanidm_dir'} // File::Temp->newdir(CLEANUP => 0);

    my $self = {
        kanidm_dir => $kanidm_dir,
        kanidm_config => "$kanidm_dir/kanidm.toml",
        # Might get overwritten by generate_config if it's undef here.
        port => $opts{'port'},
        _explicit_port => defined $opts{'port'},
        _logfile => "$kanidm_dir/kanidm.log"
    };
    my $blessed = bless $self, $class;


    return $blessed;
}

sub start {
    my ($self) = @_;

START_DAEMON:
    $self->generate_config();
    my $pid = fork;
    die "Failed to fork when starting Kanidm" if not defined $pid;

    if ($pid == 0) {
        # Redirect kanidm output to a logfile so we can look at it in the other branch, without
        # having to take permenant responsibility for draining an actual pipe connected to that
        # process.
        open(STDOUT, '>', $self->{_logfile}) or die "Cannot redirect STDOUT: $!";
        open(STDERR, '>&STDOUT') or die "Cannot dup STDERR: $!";
        exec('kanidmd', '--config-path', $self->{kanidm_config}, "server")
            or die "Could not start kanidm: $!";
    } else {
        $self->{_pid} = $pid;
    }

    eval { $self->wait_for_ready() };
    if ($@) {
        goto START_DAEMON if $@ =~ /port conflict/ and not $self->{_explicit_port};
        die $@;
    }

    $self->{admin_password} = $self->read_or_recover_password('admin');
    $self->{idm_admin_password} = $self->read_or_recover_password('idm_admin');
}

sub generate_config {
    my ($self) = @_;

    # Generate a random port number
    if (!$self->{_explicit_port}) {
        $self->{port} = int(rand(32768 - 1024)) + 1024;
    }

    # Stamp out a config file with that port number
    open(my $fh, '>', $self->{kanidm_config}) or die "Cannot open $self->{kanidm_config}: $!";
    print $fh <<EOF;
version = "2"
bindaddress = "[::1]:$self->{port}"
db_path = "$self->{kanidm_dir}/kanidm.db"
tls_chain = "$self->{kanidm_dir}/chain.pem"
tls_key = "$self->{kanidm_dir}/key.pem"
domain = "localhost"
origin = "https://localhost:$self->{port}"
adminbindpath = "$self->{kanidm_dir}/admin.sock"
EOF
    close($fh);

    # Generate the TLS certificates specified in the config file (this is a no-op if they already
    # exist at that location, and returns status zero in that case)
    system("kanidmd", "--config-path", $self->{kanidm_config}, "cert-generate") == 0
        or die "Failed to start Kanidm";
}

sub wait_for_ready {
    my ($self) = @_;

    my $logfile = $self->{_logfile};
    my $max_attempts = 60;

    for (my $i = 0; $i < $max_attempts; $i++) {
        eval { $self->assert_running(); };
        if ($@) {
            # If kanidm crashed, check the logfile to see if it's because of a port conflict; if
            # so, we'll want to retry on a different port. Unfortunately kanidm can't just bind to
            # a random port and _tell_ us what it bound to, because while providing ":0" as the
            # port in bindaddress works, it
            #   1) doesn't actually print the bound port, and
            #   2) requires the port number in the origin config option anyway
            my @log_contents = do { my $fh; open $fh, '<', $logfile and <$fh> };
            if (grep /kind: AddrInUse/, @log_contents) {
                die 'port conflict detected';
            }
            die $@;
        }

        my $ua = $self->make_ua();
        my $res = $ua->get($self->url("/status"));
        if ($res->is_success and $res->decoded_content =~ /\s*true\s*/) {
            return;
        }

        sleep 1
    }

    die "Kanidm process (PID $self->{_pid}) did not become ready in time. " .
        "Check log file: $logfile";
}

sub assert_running {
    my ($self) = @_;

    my $pid_status = waitpid($self->{_pid}, WNOHANG);
    return unless $pid_status > 0;

    my $logfile = $self->{_logfile};
    die "Kanidm process (PID $self->{_pid}) exited before becoming ready. " .
        "Check log file: $logfile";
}

sub make_ua {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(timeout => 10);
    $ua->ssl_opts(SSL_ca_file => "$self->{kanidm_dir}/ca.pem");
    return $ua;
}

sub url {
    my ($self, $path) = @_;
    return "https://localhost:$self->{port}" . ($path // '');
}

sub read_or_recover_password {
    my ($self, $user) = @_;

    my $password;

    # If we had previously written a password for this user in this database dir, use it; otherwise,
    # generate a new one.
    if (-e $self->{kanidm_dir} . "/${user}_password") {
        open(my $fh, '<', $self->{kanidm_dir} . "/${user}_password")
            or die "Cannot open $user password file: $!";
        $password = <$fh>;
        chomp $password;
        close($fh);
    } else {
        $password = $self->recover_password($user);
        open(my $fh, '>', $self->{kanidm_dir} . "/${user}_password")
            or die "Cannot write $user password file: $!";
        print $fh $password;
        close($fh);
    }

    return $password;
}

sub recover_password {
    my ($self, $user) = @_;

    my @lines = do {
        open my $fh, '-|', 'kanidmd', '--config-path', $self->{kanidm_config},
            'recover-account', $user, '--output', 'json'
            or die "Failed to run kanidmd command: $!";
        <$fh>;
    };
    # Annoyingly this command spits out a lot of not-json in the same stdout stream as the json.
    # This is fixed in kanidm as of two weeks ago (https://github.com/kanidm/kanidm/pull/4075)
    # But not in nixpkgs yet
    my $json_text = join '', grep { /^\s*{/ } @lines;
    my $json = decode_json($json_text);
    return $json->{password};
}

sub admin_password {
    my ($self) = @_;
    return $self->{admin_password};
}

sub logfile {
    my ($self) = @_;
    return $self->{_logfile};
}

sub kill {
    my ($self) = @_;
    if ($self->{_pid}) {
        kill SIGTERM, $self->{_pid};
        waitpid($self->{_pid}, 0);
        undef $self->{_pid};
    }
}

sub login_with_password {
    my ($self, $username, $password) = @_;

    # Auth in kanidm is a multi-step process:
    # 1) Begin an auth session for a user
    # 2) Select an auth method
    # 3) Provide the credential

    my $ua = $self->make_ua();

    my $step1_res = $ua->post(
        $self->url('/v1/auth'),
        'Content-Type' => 'application/json',
        Content => encode_json({
            step => {
                init2 => {
                    username => $username,
                    privileged => JSON::MaybeXS::true,
                    issue => 'token',
                }
            }
        })
    );
    $step1_res->is_success or die "failed to start auth session: " . $step1_res->status_line;
    my $step1_body = decode_json($step1_res->decoded_content);
    grep { $_ eq 'password' } @{$step1_body->{state}->{choose}}
        or die "password method not available";

    my $step2_res = $ua->post(
        $self->url('/v1/auth'),
        'Content-Type' => 'application/json',
        'X-Kanidm-Auth-Session-Id' => $step1_res->header('X-Kanidm-Auth-Session-Id'),
        Content => encode_json({
            step => {
                begin => 'password',
            }
        })
    );
    $step2_res->is_success or die "failed to select password method: " . $step2_res->status_line;
    my $step2_body = decode_json($step2_res->decoded_content);
    grep { $_ eq 'password' } @{$step2_body->{state}->{continue}}
        or die "password method not continuable";

    my $step3_res = $ua->post(
        $self->url('/v1/auth'),
        'Content-Type' => 'application/json',
        'X-Kanidm-Auth-Session-Id' => $step1_res->header('X-Kanidm-Auth-Session-Id'),
        Content => encode_json({
            step => {
                cred => {
                    password => $password,
                }
            }
        })
    );
    $step3_res->is_success or die "failed to provide password: " . $step3_res->status_line;
    my $step3_body = decode_json($step3_res->decoded_content);
    my $token = $step3_body->{state}->{success};
    $token or die "kanidm did not provide token in response body";

    return $token;
}

sub admin_token {
    my ($self) = @_;
    return $self->{_admin_token} //=
        $self->login_with_password('admin', $self->{admin_password});
}

sub idm_admin_token {
    my ($self) = @_;
    return $self->{_idm_admin_token} //=
        $self->login_with_password('idm_admin', $self->{idm_admin_password});
}

sub group_exists {
    my ($self, $group) = @_;

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $get_res = $ua->get(
        $self->url("/v1/group/$group"),
        'Authorization' => "Bearer $token",
        'Content-Type' => 'application/json',
    );
    return 0 unless $get_res->code == 200;
    # Annoyingly, kanidm returns 200 for non-existent users too
    # It just has null in the body for those.
    return defined decode_json($get_res->decoded_content);
}

sub create_group {
    my ($self, $group) = @_;

    return if $self->group_exists($group);

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $create_res = $ua->post(
        $self->url('/v1/group'),
        'Authorization' => "Bearer $token",
        'Content-Type' => 'application/json',
        Content => encode_json({
            attrs => {
                name => [$group],
            }
        })
    );
    $create_res->is_success or die "failed to create group: " . $create_res->status_line;
}

sub create_user {
    my ($self, $user, %opts) = @_;

    my $attrs = {
        name => [$user],
        displayname => [$opts{display_name} // $user],
        mail => [$opts{mail} // "$user\@localhost"],
    };

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();

    if (not $self->user_exists($user)) {
        my $create_res = $ua->post(
            $self->url('/v1/person'),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json({
                attrs => $attrs,
            })
        );
        $create_res->is_success or die "failed to create user: " . $create_res->status_line;
    }

    if (defined $opts{groups}) {
        foreach my $group (@{$opts{groups}}) {
            my $add_res = $ua->post(
                $self->url("/v1/group/$group/_attr/member"),
                'Authorization' => "Bearer $token",
                'Content-Type' => 'application/json',
                Content => encode_json([$user])
            );
            $add_res->is_success or die "failed to add user to group: " . $add_res->status_line;
        }
    }

    if (defined $opts{password}) {
        my $update_res = $ua->get(
            $self->url("/v1/person/$user/_credential/_update"),
            'Authorization' => "Bearer $token",
        );
        $update_res->is_success
            or die "failed to initiate user credential update: " . $update_res->status_line;
        my $update_res_body = decode_json($update_res->decoded_content);
        my $update_token = $update_res_body->[0]->{token}
            or die "missing token in credential update response";

        my $pw_set_res = $ua->post(
            $self->url("/v1/credential/_update"),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json([{ password => $opts{password}}, { token => $update_token }])
        );
        $pw_set_res->is_success or die "failed to set password: " . $pw_set_res->status_line;

        my $commit_res = $ua->post(
            $self->url("/v1/credential/_commit"),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json({ token => $update_token })
        );
        $commit_res->is_success or die "failed to commit cred update: " . $commit_res->status_line;
    }
}

sub user_exists {
    my ($self, $user) = @_;
    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $get_res = $ua->get(
        $self->url("/v1/person/$user"),
        'Authorization' => "Bearer $token",
    );
    return 0 unless $get_res->code == 200;
    return defined decode_json($get_res->decoded_content);
}

sub create_oauth2_client {
    my ($self, %opts) = @_;

    my $name = $opts{name} or die 'name is required';
    my $redirect_uris = $opts{redirect_uris};
    my $display_name = $opts{display_name} // $name;
    my $landing_page = $opts{landing_page} // do {
        my $uri = URI->new($redirect_uris->[0]);
        $uri->path('/');
        $uri->query(undef);
        $uri->fragment(undef);
        $uri->as_string;
    };
    my $scopes = $opts{scopes} // {};
    my $claims = $opts{claims} // {};

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();

    if (not $self->oauth2_client_exists($name)) {
        my $create_res = $ua->post(
            $self->url('/v1/oauth2/_basic'),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json({
                attrs => {
                    name => [$name],
                    displayname => [$display_name],
                    oauth2_rs_origin_landing => [$landing_page],
                    oauth2_strict_redirect_uri => ['true'],
                }
            })
        );
        $create_res->is_success or die "failed to create client: " . $create_res->status_line;
    }

    foreach my $redirect_uri (@$redirect_uris) {
        my $add_uri_res = $ua->post(
            $self->url("/v1/oauth2/$name/_attr/oauth2_rs_origin"),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json([$redirect_uri]),
        );
        $add_uri_res->is_success or die "failed to add redirect URI: " . $add_uri_res->status_line;
    }

    foreach my $group (keys %{$scopes}) {
        my $update_scopemap_res = $ua->post(
            $self->url("/v1/oauth2/$name/_scopemap/$group"),
            'Authorization' => "Bearer $token",
            'Content-Type' => 'application/json',
            Content => encode_json($scopes->{$group}),
        );
        $update_scopemap_res->is_success
            or die "failed to add scopes to group: " . $update_scopemap_res->status_line;
    }

    foreach my $claim (keys %{$claims}) {
        foreach my $group (keys %{$claims->{$claim}}) {
            my $claim_values = $claims->{$claim}->{$group};
            my $claim_set_res = $ua->post(
                $self->url("/v1/oauth2/$name/_claimmap/$claim/$group"),
                'Authorization' => "Bearer $token",
                'Content-Type' => 'application/json',
                Content => encode_json($claim_values),
            );
            $claim_set_res->is_success
                or die "failed to add claims: " . $claim_set_res->status_line . "\n" . $claim_set_res->decoded_content;
        }
    }
}

sub oauth2_client_exists {
    my ($self, $name) = @_;

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $get_res = $ua->get(
        $self->url("/v1/oauth2/$name"),
        'Authorization' => "Bearer $token",
        'Content-Type' => 'application/json',
    );
    return 0 unless $get_res->code == 200;
    return defined decode_json($get_res->decoded_content);
}

sub get_oauth2_secret {
    my ($self, $name) = @_;

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $secret_res = $ua->get(
        $self->url("/v1/oauth2/$name/_basic_secret"),
        'Authorization' => "Bearer $token",
        'Content-Type' => 'application/json',
    );
    $secret_res->is_success or die "failed to get client secret: " . $secret_res->status_line;
    my $secret_res_body = decode_json($secret_res->decoded_content);
    return $secret_res_body;
}

sub allow_passwords {
    my ($self) = @_;

    my $ua = $self->make_ua();
    my $token = $self->idm_admin_token();
    my $res = $ua->put(
        $self->url("/v1/group/idm_all_persons/_attr/credential_type_minimum"),
        'Authorization' => "Bearer $token",
        'Content-Type' => 'application/json',
        Content => encode_json(['any'])
    );
    $res->is_success or die "failed to allow passwords: " . $res->status_line;
}

sub DESTROY {
    my ($self) = @_;
    $self->kill();
}

1;
