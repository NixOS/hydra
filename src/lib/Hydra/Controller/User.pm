package Hydra::Controller::User;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Crypt::RandPasswd;
use Digest::SHA1 qw(sha1_hex);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use LWP::UserAgent;
use JSON;
use HTML::Entities;


__PACKAGE__->config->{namespace} = '';


sub login :Local :Args(0) :ActionClass('REST') { }

sub login_POST {
    my ($self, $c) = @_;

    my $username = $c->stash->{params}->{username} // "";
    my $password = $c->stash->{params}->{password} // "";

    error($c, "You must specify a user name.") if $username eq "";
    error($c, "You must specify a password.") if $password eq "";

    accessDenied($c, "Bad username or password.")
        if !$c->authenticate({username => $username, password => $password});

    $self->status_no_content($c);
}


sub logout :Local :Args(0) :ActionClass('REST') { }

sub logout_POST {
    my ($self, $c) = @_;
    $c->flash->{flashMsg} = "You are no longer signed in." if $c->user_exists();
    $c->logout;
    $self->status_no_content($c);
}


sub persona_login :Path('/persona-login') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);

    my $assertion = $c->req->params->{assertion} or die;

    my $ua = new LWP::UserAgent;
    my $response = $ua->post(
        'https://verifier.login.persona.org/verify',
        { assertion => $assertion,
          audience => $c->uri_for('/')
        });
    error($c, "Did not get a response from Persona.") unless $response->is_success;

    my $d = decode_json($response->decoded_content) or die;
    error($c, "Persona says: $d->{reason}") if $d->{status} ne "okay";

    my $email = $d->{email} or die;

    # Be paranoid about the email address format, since we do use it
    # in URLs.
    die "Illegal email address." unless $email =~ /^[a-zA-Z0-9\.\-\_]+@[a-zA-Z0-9\.\-\_]+$/;

    my $user = $c->find_user({ username => $email });

    if (!$user) {
        $c->model('DB::Users')->create(
            { username => $email
            , password => "!"
            , emailaddress => $email,
            , type => "persona"
            });
        $user = $c->find_user({ username => $email }) or die;
    }

    $c->set_authenticated($user);

    $self->status_no_content($c);
    $c->flash->{successMsg} = "You are now signed in as <tt>" . encode_entities($email) . "</tt>.";
}


sub captcha :Local Args(0) {
    my ($self, $c) = @_;
    $c->create_captcha();
}


sub isValidPassword {
    my ($password) = @_;
    return length($password) >= 6;
}


sub setPassword {
    my ($user, $password) = @_;
    $user->update({ password => sha1_hex($password) });
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

    my $userName = trim $c->req->params->{username};
    $c->stash->{username} = $userName;

    error($c, "You did not enter the correct digits from the security image.")
        unless isAdmin($c) || $c->validate_captcha($c->req->param('captcha'));

    error($c, "Your user name is invalid. It must start with a lower-case letter followed by lower-case letters, digits, dots or underscores.")
        if $userName !~ /^$userNameRE$/;

    error($c, "Your user name is already taken.")
        if $c->find_user({ username => $userName });

    txn_do($c->model('DB')->schema, sub {
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

    my $fullName = trim($c->req->params->{fullname} // "");
    error($c, "Your must specify your full name.") if $fullName eq "";

    my $password = trim($c->req->params->{password} // "");
    if ($user->type eq "hydra" && ($user->password eq "!" || $password ne "")) {
        error($c, "You must specify a password of at least 6 characters.")
            unless isValidPassword($password);

        error($c, "The passwords you specified did not match.")
            if $password ne trim $c->req->params->{password2};

        setPassword($user, $password);
    }

    my $emailAddress = trim($c->req->params->{emailaddress} // "");
    # FIXME: validate email address?

    $user->update(
        { fullname => $fullName
        , emailonerror => $c->stash->{params}->{"emailonerror"} ? 1 : 0
        });

    if (isAdmin($c)) {
        $user->update({ emailaddress => $emailAddress })
            if $user->type eq "hydra";

        $user->userroles->delete;
        $user->userroles->create({ role => $_ })
            foreach paramToList($c, "roles");
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

    txn_do($c->model('DB')->schema, sub {
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
    setPassword($user, $password);
    sendEmail($c,
        $user->emailaddress,
        "Hydra password reset",
        "Hi,\n\n".
        "Your password has been reset. Your new password is '$password'.\n\n".
        "You can change your password at " . $c->uri_for($self->action_for('edit'), [$user->username]) . ".\n\n".
        "With regards,\n\nHydra.\n"
    );

    $c->flash->{successMsg} = "A new password has been sent to ${\$user->emailaddress}.";
    $self->status_no_content($c);
}


sub dashboard :Chained('user') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard.tt';

    # Get the N most recent builds for each starred job.
    $c->stash->{starredJobs} = [];
    foreach my $j ($c->stash->{user}->starredjobs->search({}, { order_by => ['project', 'jobset', 'job'] })) {
        my @builds = $j->job->builds->search(
            { },
            { rows => 20, order_by => "id desc" });
        push $c->stash->{starredJobs}, { job => $j->job, builds => [@builds] };
    }
}


sub my_jobs_tab :Chained('user') :PathPart('my-jobs-tab') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard-my-jobs-tab.tt';

    die unless $c->stash->{user}->emailaddress;

    # Get all current builds of which this user is a maintainer.
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        { iscurrent => 1
        , maintainers => { ilike => "%" . $c->stash->{user}->emailaddress . "%" }
        },
        { order_by => ["project", "jobset", "job"] })];
}


1;
