package Hydra::Controller::User;

use utf8;
use strict;
use warnings;
use base 'Catalyst::Controller';
use Crypt::RandPasswd;
use Digest::SHA1 qw(sha1_hex);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


__PACKAGE__->config->{namespace} = '';


sub login :Local {
    my ($self, $c) = @_;

    my $username = $c->request->params->{username} || "";
    my $password = $c->request->params->{password} || "";

    if ($username eq "" && $password eq "" && !defined $c->session->{referer}) {
        my $baseurl = $c->uri_for('/');
        my $referer = $c->request->referer;
        $c->session->{referer} = $referer if defined $referer && $referer =~ m/^($baseurl)/;
    }

    if ($username && $password) {
        backToReferer($c) if $c->authenticate({username => $username, password => $password});
        $c->stash->{errorMsg} = "Bad username or password.";
    }

    $c->stash->{template} = 'login.tt';
}


sub logout :Local {
    my ($self, $c) = @_;
    $c->logout;
    $c->response->redirect($c->request->referer || $c->uri_for('/'));
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

    die "Not implemented!\n";

    $c->stash->{template} = 'user.tt';
    $c->stash->{create} = 1;
    return if $c->request->method ne "POST";

    my $userName = trim $c->req->params->{username};
    my $fullName = trim $c->req->params->{fullname};
    my $password = trim $c->req->params->{password};
    $c->stash->{username} = $userName;
    $c->stash->{fullname} = $fullName;

    sub fail {
        my ($c, $msg) = @_;
        $c->stash->{errorMsg} = $msg;
    }

    return fail($c, "You did not enter the correct digits from the security image.")
        unless $c->validate_captcha($c->req->param('captcha'));

    return fail($c, "Your user name is invalid. It must start with a lower-case letter followed by lower-case letters, digits, dots or underscores.")
        if $userName !~ /^$userNameRE$/;

    return fail($c, "Your user name is already taken.")
        if $c->find_user({ username => $userName });

    return fail($c, "Your must specify your full name.") if $fullName eq "";

    return fail($c, "You must specify a password of at least 6 characters.")
        unless isValidPassword($password);

    return fail($c, "The passwords you specified did not match.")
        if $password ne trim $c->req->params->{password2};

    txn_do($c->model('DB')->schema, sub {
        my $user = $c->model('DB::Users')->create(
            { username => $userName
            , fullname => $fullName
            , password => "!"
            , emailaddress => "",
            });
        setPassword($user, $password);
    });

    unless ($c->user_exists) {
        $c->authenticate({username => $userName, password => $password})
            or error($c, "Unable to authenticate the new user!");
    }

    $c->flash->{successMsg} = "User <tt>$userName</tt> has been created.";
    backToReferer($c);
}


sub user :Chained('/') PathPart('user') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    requireLogin($c) if !$c->user_exists;

    error($c, "You do not have permission to edit other users.")
        if $userName ne $c->user->username && !isAdmin($c);

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");
}


sub deleteUser {
    my ($self, $c, $user) = @_;
    my ($project) = $c->model('DB::Projects')->search({ owner => $user->username });
    error($c, "User " . $user->username . " is still owner of project " . $project->name . ".")
        if defined $project;
    $c->logout() if $user->username eq $c->user->username;
    $user->delete;
}


sub edit :Chained('user') Args(0) {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};

    $c->stash->{template} = 'user.tt';

    $c->session->{referer} = $c->request->referer if !defined $c->session->{referer};

    if ($c->request->method ne "POST") {
        $c->stash->{fullname} = $user->fullname;
        $c->stash->{emailonerror} = $user->emailonerror;
        return;
    }

    if (($c->request->params->{submit} // "") eq "delete") {
        deleteUser($self, $c, $user);
        backToReferer($c);
    }

    if (($c->request->params->{submit} // "") eq "reset-password") {
        $c->stash->{json} = {};
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
        return;
    }

    my $fullName = trim $c->req->params->{fullname};

    txn_do($c->model('DB')->schema, sub {

        error($c, "Your must specify your full name.") if $fullName eq "";

        $user->update(
            { fullname => $fullName
            , emailonerror => $c->request->params->{"emailonerror"} ? 1 : 0
            });

        my $password = $c->req->params->{password} // "";
        if ($password ne "") {
            error($c, "You must specify a password of at least 6 characters.")
                unless isValidPassword($password);
            error($c, "The passwords you specified did not match.")
                if $password ne trim $c->req->params->{password2};
            setPassword($user, $password);
        }

        if (isAdmin($c)) {
            $user->userroles->delete_all;
            $user->userroles->create({ role => $_})
                foreach paramToList($c, "roles");
        }

    });

    backToReferer($c);
}


1;
