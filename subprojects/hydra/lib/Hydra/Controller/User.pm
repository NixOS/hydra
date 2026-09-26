package Hydra::Controller::User;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use File::Slurper qw(read_text);
use Crypt::RandPasswd;
use Digest::SHA1 qw(sha1_hex);
use Hydra::Config qw(getLDAPConfigAmbient localAuthEnabled passwordSigninEnabled);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Email;
use Hydra::Helper::OIDC;
use Hydra::Config;
use LWP::UserAgent;
use URI;
use JSON::MaybeXS;
use String::Compare::ConstantTime qw(equals);
use HTML::Entities;
use Encode qw(decode);


__PACKAGE__->config->{namespace} = '';


sub login :Local :Args(0) :ActionClass('REST') { }

sub login_POST {
    my ($self, $c) = @_;

    accessDenied($c, "Signing in with a password is disabled on this Hydra.")
        unless passwordSigninEnabled($c->config);

    my $username = $c->stash->{params}->{username} // "";
    my $password = $c->stash->{params}->{password} // "";

    badRequest($c, "You must specify a user name.") if $username eq "";
    badRequest($c, "You must specify a password.") if $password eq "";

    if ($c->get_auth_realm('ldap') && $c->authenticate({username => $username, password => $password}, 'ldap')) {
        doLDAPLogin($self, $c, $username);
    } elsif (localAuthEnabled($c->config) && $c->authenticate({username => $username, password => $password})) {}
    else {
        accessDenied($c, "Bad username or password.")
    }

    $self->status_found(
        $c,
        location => $c->uri_for("current-user"),
        entity => $c->model("DB::Users")->find($c->user->username)
    );
}


sub logout :Local :Args(0) :ActionClass('REST') { }

sub logout_POST {
    my ($self, $c) = @_;
    $c->flash->{flashMsg} = "You are no longer signed in." if $c->user_exists();
    $c->logout;
    $self->status_no_content($c);
}

sub logout_GET {
    my ($self, $c) = @_;

    # CSRF protection: require a token derived from the session ID so that
    # a cross-site <img>/<a>/top-level navigation cannot log the user out.
    my $expected = logoutToken($c);
    my $token = $c->req->params->{token} // "";
    error($c, "Invalid CSRF token", 403)
        unless defined $expected && equals($token, $expected);

    $c->flash->{flashMsg} = "You are no longer signed in." if $c->user_exists();

    my $oidc_provider = $c->session->{oidc_provider};
    $c->logout;
    $c->delete_session("Logout");

    # If this was an OIDC session and the IdP advertises an end_session_endpoint,
    # redirect there so the user is also logged out of the IdP (RP-Initiated Logout).
    # The endpoint may come from discovery, which this worker may not have done
    # yet. If the IdP is unreachable, still complete the local logout.
    if (defined $oidc_provider) {
        my $provider = eval { Hydra::Helper::OIDC::providerConf($c, $oidc_provider) };
        $c->log->warn("Skipping OIDC RP-Initiated Logout: $@") unless $provider;
        if (defined $provider && defined $provider->{end_session_endpoint}) {
            my $uri = URI->new($provider->{end_session_endpoint});
            $uri->query_form(
                post_logout_redirect_uri => $c->uri_for("/")->as_string,
                client_id => $provider->{client_id},
            );
            $c->res->redirect($uri);
            return;
        }
    }

    $c->res->redirect($c->uri_for("/"));
}

sub doLDAPLogin {
    my ($self, $c, $username) = @_;
    my $user = $c->find_user({ username => $username });
    my $LDAPUser = $c->find_user({ username => $username }, 'ldap');
    my @LDAPRoles = $LDAPUser->roles;
    my $role_mapping = getLDAPConfigAmbient()->{"role_mapping"};

    if (!$user) {
        $c->model('DB::Users')->create(
            { username => $username
            , fullname => decode('UTF-8', $LDAPUser->cn)
            , password => "!"
            , emailaddress => $LDAPUser->mail
            , type => "LDAP"
        });
        $user = $c->find_user({ username => $username }) or die;
    } else {
        $user->update(
            { fullname => decode('UTF-8', $LDAPUser->cn)
            , password => "!"
            , emailaddress => $LDAPUser->mail
            , type => "LDAP"
        });
    }
    $user->userroles->delete;
    foreach my $ldap_role (@LDAPRoles) {
        if (defined($role_mapping->{$ldap_role})) {
            my $roles = $role_mapping->{$ldap_role};
            for my $mapped_role (@$roles) {
                $user->userroles->create({ role => $mapped_role });
            }
        }
    }
    $c->set_authenticated($user);
}

# Addresses as they turn up in claims from an identity provider or in the
# preferences form. Hydra stores them, mails them and puts them in URLs, so this
# is stricter than "has an @ in it" and looser than a full RFC 5322 parser:
# quoted local parts, comments, IP-literal domains and non-ASCII addresses are
# not accepted, and single-label domains such as `localhost` are, since Hydra
# runs on internal networks.
#
# A `+` is allowed in the local part, because subaddressed addresses are common.
sub valid_email_address {
    my ($email) = @_;
    return 0 unless defined $email;
    return 0 if length($email) > 254;

    # The local part is a dot-atom: runs of the allowed characters joined by
    # single dots, so no leading, trailing or doubled dots. The set is kept to
    # the characters that survive a round trip through a URL path segment, since
    # Hydra puts usernames (which are email addresses for GitHub logins) in
    # URLs: `+` is there because subaddressed addresses are common, and the rest
    # of the RFC 5322 atext set is not, because Catalyst escapes `/`, `?` and
    # `#` but not `%`, so a `%41` in an address would decode to a different
    # username in every link.
    my $atext = qr{[a-zA-Z0-9_+-]};
    # A domain is DNS labels, which may not start or end with a dash or be
    # empty.
    my $label = qr{[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?};

    return 0 unless $email =~ m{\A ($atext+ (?: \. $atext+ )*) \@ ($label (?: \. $label )*) \z}x;

    # RFC 5321 length limits.
    return length($1) <= 64 && length($2) <= 253;
}

sub doEmailLogin {
    my ($self, $c, %args) = @_;
    my ($type, $email, $fullName) = @args{qw(type email fullName)};
    my $username = $args{username} // $email;

    die "No email address provided.\n" unless defined $email;

    die "Illegal email address.\n" unless valid_email_address($email);

    # If allowed_domains is set, check if the email address
    # returned is on these domains.  When not configured, allow all
    # domains.
    my $allowed_domains = $c->config->{allowed_domains} // ($c->config->{persona_allowed_domains} // "");
    if ($allowed_domains ne "") {
        my $email_ok = 0;
        my @domains = split /,/, $allowed_domains;
        map { $_ =~ s/^\s*(.*?)\s*$/$1/ } @domains;

        foreach my $domain (@domains) {
            $email_ok = $email_ok || ((split /@/, $email)[1] eq $domain);
        }
        error($c, "Your email address does not belong to a domain that is allowed to log in.\n")
            unless $email_ok;
    }

    my $user = $c->find_user({ username => $username });

    if ($user) {
        die "You cannot login via login type '$type'.\n" if $user->type ne $type;
    } else {
        $c->model('DB::Users')->create(
            { username => $username
            , fullname => $fullName,
            , password => "!"
            , emailaddress => $email,
            , type => $type
            });
        $user = $c->find_user({ username => $username }) or die;
    }

    $c->set_authenticated($user);

    $self->status_no_content($c);
    $c->flash->{successMsg} = "You are now signed in as <tt>" . encode_entities($email) . "</tt>.";
}

sub github_login :Path('/github-login') Args(0) {
    my ($self, $c) = @_;

    my $client_id = $c->config->{github_client_id} or die "github_client_id not configured.";
    my $client_secret = $c->config->{github_client_secret} // do {
        my $client_secret_file = $c->config->{github_client_secret_file} or die "github_client_secret nor github_client_secret_file is configured.";
        my $client_secret = read_text($client_secret_file);
        $client_secret =~ s/\s+//;
        $client_secret;
    };
    die "No github secret configured" unless $client_secret;

    my $ua = LWP::UserAgent->new();
    my $response = $ua->post(
        'https://github.com/login/oauth/access_token',
        {
            client_id => $client_id,
            client_secret => $client_secret,
            code => ($c->req->params->{code} // die "No token."),
        }, Accept => 'application/json');
    error($c, "Did not get a response from GitHub.") unless $response->is_success;

    my $data = decode_json($response->decoded_content) or die;
    my $access_token = $data->{access_token} // die "No access_token in response from GitHub.";

    $response = $ua->get('https://api.github.com/user/emails', Accept => 'application/vnd.github.v3+json', Authorization => "token $access_token");
    error($c, "Did not get a response from GitHub for email info.") unless $response->is_success;

    $data = decode_json($response->decoded_content) or die;
    my $email;

    foreach my $eml (@{$data}) {
        $email = $eml->{email} if $eml->{verified} && $eml->{primary};
    }

    die "No primary email for this GitHub profile" unless $email;

    $response = $ua->get('https://api.github.com/user', Authorization => "token $access_token");
    error($c, "Did not get a response from GitHub for user info.") unless $response->is_success;
    $data = decode_json($response->decoded_content) or die;

    doEmailLogin($self, $c,
        type => "github",
        email => $email,
        fullName => $data->{name} // undef,
    );

    $c->res->redirect($c->uri_for($c->res->cookies->{'after_github'}));
}

sub github_redirect :Path('/github-redirect') Args(0) {
    my ($self, $c) = @_;

    my $client_id = $c->config->{github_client_id} or die "github_client_id not configured.";

    my $after = "/" . $c->req->params->{after};

    $c->res->cookies->{'after_github'} = {
        name => 'after_github',
        value => $after,
    };

    $c->res->redirect("https://github.com/login/oauth/authorize?client_id=$client_id&scope=user:email");
}

sub oidc_redirect :Path('/oidc-redirect') Args(1) {
    my ($self, $c, $provider_name) = @_;

    # Sanitize the 'after' parameter to prevent open redirects, so that e.g.
    # '//evil.com' cannot become a protocol-relative URL. Browsers drop
    # tabs/newlines from URLs and treat '\' like '/', so remove control
    # characters and backslashes before stripping leading slashes.
    my $after = $c->req->params->{after} // "";
    $after =~ s{[[:cntrl:]\\]}{}g;
    $after =~ s{^/+}{};

    my $oidc = Hydra::Helper::OIDC->new($c,
        provider_name => $provider_name,
        after => "/" . $after,
        redirect_uri => $c->uri_for("/oidc-callback", $provider_name)->as_string,
    );
    $c->res->redirect($oidc->authorizationURL());
}

sub oidc_callback :Path('/oidc-callback') Args(1) {
    my ($self, $c, $provider_name) = @_;

    my $oidc = Hydra::Helper::OIDC->load($c, provider_name => $provider_name);
    my $authorization_code = $oidc->validateAuthorizationCode($c->req->params);
    my $token = $oidc->exchangeCodeForToken($authorization_code);
    my $claims = $oidc->validateToken($token);

    # doEmailLogin checks allowed_domains against this address, so refuse
    # addresses the IdP says it has not verified.
    my $verified = $claims->{email_verified};
    error($c, "Your OIDC provider has not verified your email address.", 403)
        if defined $verified && (!$verified || $verified eq 'false');

    doEmailLogin($self, $c,
        type => 'oidc',
        email => $claims->{email},
        fullName => $claims->{name},
        username => $provider_name . ":" . $claims->{sub},
    );

    # Keep the profile in sync with the IdP for returning users.
    $c->user->get_object->update({
        emailaddress => $claims->{email},
        defined $claims->{name} ? (fullname => $claims->{name}) : (),
    });

    # See the OIDC documentation for how the role claim and the provider's
    # role_mapping turn the IDP's claims into roles. $roles is undef if the
    # IDP did not present a role claim at all, in which case we leave the
    # user's roles alone rather than revoking them.
    my $roles = Hydra::Config::oidc_roles_from_claim($oidc->{conf}, $claims);
    $c->user->setRoles(@$roles) if $roles;

    $oidc->clear_session();
    # Remember which OIDC provider was used so we can perform RP-Initiated
    # Logout against its end_session_endpoint when the user signs out.
    $c->session->{oidc_provider} = $provider_name;
    $c->res->redirect($oidc->after());
}


sub captcha :Local Args(0) {
    my ($self, $c) = @_;
    $c->create_captcha();
}


sub isValidPassword {
    my ($password) = @_;
    return length($password) >= 6;
}


sub register :Local Args(0) {
    my ($self, $c) = @_;

    accessDenied($c, "User registration is currently not implemented.") unless isAdmin($c);

    if ($c->request->method eq "GET") {
        $c->stash->{template} = 'user.tt';
        $c->stash->{create} = 1;
        return;
    }

    die unless $c->request->method eq "PUT";

    my $userName = trim $c->stash->{params}->{username};
    $c->stash->{username} = $userName;

    error($c, "You did not enter the correct digits from the security image.")
        unless isAdmin($c) || $c->validate_captcha($c->req->param('captcha'));

    error($c, "Your user name is invalid. It must start with a lower-case letter followed by lower-case letters, digits, dots or underscores.")
        if $userName !~ /^$userNameRE$/;

    error($c, "Your user name is already taken.")
        if $c->find_user({ username => $userName });

    $c->model('DB')->schema->txn_do(sub {
        my $user = $c->model('DB::Users')->create(
            { username => $userName
            , password => "!"
            , emailaddress => "",
            , type => "hydra"
            });
        updatePreferences($c, $user);
    });

    unless ($c->user_exists) {
        $c->set_authenticated({username => $userName})
            or error($c, "Unable to authenticate the new user!");
    }

    $c->flash->{successMsg} = "User <tt>$userName</tt> has been created.";
    $self->status_no_content($c);
}


sub updatePreferences {
    my ($c, $user) = @_;

    my $fullName = trim($c->stash->{params}->{fullname} // "");
    error($c, "Your must specify your full name.") if $fullName eq "";

    my $password = trim($c->stash->{params}->{password} // "");
    if ($user->type eq "hydra" && ($user->password eq "!" || $password ne "")) {
        error($c, "You must specify a password of at least 6 characters.")
            unless isValidPassword($password);

        error($c, "The passwords you specified did not match.")
            if $password ne trim $c->stash->{params}->{password2};

        $user->setPassword($password);
    }

    my $emailAddress = trim($c->stash->{params}->{emailaddress} // "");
    # Not setting an email address is allowed, but anything that claims to be
    # one has to look like one.
    error($c, "The email address is not a valid email address.", 400)
        if $emailAddress ne "" && !valid_email_address($emailAddress);

    $user->update(
        { fullname => $fullName
        , emailonerror => $c->stash->{params}->{"emailonerror"} ? 1 : 0
        , publicdashboard => $c->stash->{params}->{"publicdashboard"} ? 1 : 0
        });

    if (isAdmin($c)) {
        $user->update({ emailaddress => $emailAddress })
            if $user->type eq "hydra";


        $user->setRoles(paramToList($c, "roles"));
    }
}


sub currentUser :Path('/current-user') :ActionClass('REST') { }

sub currentUser_GET {
    my ($self, $c) = @_;

    requireUser($c);

    $self->status_ok($c,
        entity => $c->model("DB::Users")->find($c->user->username)
    );
}


sub user :Chained('/') PathPart('user') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    requireUser($c);

    accessDenied($c, "You do not have permission to edit other users.")
        if $userName ne $c->user->username && !isAdmin($c);

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");
}


sub edit :Chained('user') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub edit_GET {
    my ($self, $c) = @_;
    $c->stash->{template} = 'user.tt';
}

sub edit_PUT {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    if (($c->stash->{params}->{submit} // "") eq "reset-password") {
        return;
    }

    $c->model('Db')->schema->txn_do(sub {
        updatePreferences($c, $user);
    });

    $c->flash->{successMsg} = "Your preferences have been updated.";
    $self->status_no_content($c);
}

sub edit_DELETE {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    my ($project) = $c->model('DB::Projects')->search({ owner => $user->username });
    error($c, "User " . $user->username . " is still owner of project " . $project->name . ".")
        if defined $project;

    $c->logout() if $user->username eq $c->user->username;

    $user->delete;

    $c->flash->{successMsg} = "The user has been deleted.";
    $self->status_no_content($c);
}


sub reset_password :Chained('user') :PathPart('reset-password') :Args(0) {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    requirePost($c);

    error($c, "This user's password cannot be reset.") if $user->type ne "hydra";
    error($c, "No email address is set for this user.")
        unless $user->emailaddress;

    my $password = Crypt::RandPasswd->word(8,10);
    $user->setPassword($password);
    sendEmail(
        $c->config,
        $user->emailaddress,
        "Hydra password reset",
        "Hi,\n\n".
        "Your password has been reset. Your new password is '$password'.\n\n".
        "You can change your password at " . $c->uri_for($self->action_for('edit'), [$user->username]) . ".\n\n".
        "With regards,\n\nHydra.\n",
        []
    );

    $c->flash->{successMsg} = "A new password has been sent to ${\$user->emailaddress}.";
    $self->status_no_content($c);
}


sub dashboard_old :Chained('user') :PathPart('dashboard') :Args(0) {
    my ($self, $c) = @_;
    $c->res->redirect($c->uri_for($self->action_for("dashboard"), $c->req->captures));
}


sub dashboard_base :Chained('/') PathPart('dashboard') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");

    accessDenied($c, "You do not have permission to view this dashboard.")
        unless $c->stash->{user}->publicdashboard ||
          (defined $c->user && $userName eq $c->user->username) ||
          isAdmin($c);
}


sub dashboard :Chained('dashboard_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard.tt';

    # Get the N most recent builds for each starred job.
    $c->stash->{starredJobs} = [];
    foreach my $j ($c->stash->{user}->starredjobs->search({}, { order_by => ['project', 'jobset', 'job'] })) {
        my @builds = $j->jobset->builds->search(
            { job => $j->job },
            { rows => 20, order_by => "id desc" });
        push @{$c->stash->{starredJobs}}, { job => $j, builds => [@builds] };
    }
}


sub my_jobs_tab :Chained('dashboard_base') :PathPart('my-jobs-tab') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{lazy} = 1;
    $c->stash->{template} = 'dashboard-my-jobs-tab.tt';

    error($c, "No email address is set for this user.") unless $c->stash->{user}->emailaddress;

    # Get all current builds of which this user is a maintainer.
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        { iscurrent => 1
        , maintainers => { ilike => "%" . $c->stash->{user}->emailaddress . "%" }
        , "project.enabled" => 1
        , "jobset.enabled" => 1
        },
        { order_by => ["project", "jobset", "job"]
        , join => {"jobset" => "project"}
        })];
}


sub my_jobsets_tab :Chained('dashboard_base') :PathPart('my-jobsets-tab') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard-my-jobsets-tab.tt';

    my $jobsets = $c->model('DB::Jobsets')->search(
        { "project.enabled" => 1, "me.enabled" => 1,
        , owner => $c->stash->{user}->username
        },
        { order_by => ["project", "name"]
        , join => ["project"]
        });

    $c->stash->{jobsets} = [jobsetOverview_($c, $jobsets)];
}


1;
