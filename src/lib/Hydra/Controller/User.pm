package Hydra::Controller::User;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Digest::SHA1 qw(sha1_hex);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


__PACKAGE__->config->{namespace} = '';


sub login :Local {
    my ($self, $c) = @_;

    my $username = $c->request->params->{username} || "";
    my $password = $c->request->params->{password} || "";

    if ($username eq "" && $password eq "" && !defined $c->flash->{referer}) {
        my $baseurl = $c->uri_for('/');
        my $refurl = $c->request->referer;
        $c->flash->{referer} = $refurl if $refurl =~ m/^($baseurl)/;
    }

    if ($username && $password) {
        if ($c->authenticate({username => $username, password => $password})) {
            $c->response->redirect($c->flash->{referer} || $c->uri_for('/'));
            $c->flash->{referer} = undef;
            return;
        }
        $c->stash->{errorMsg} = "Bad username or password.";
    }

    $c->keep_flash("referer");

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


sub register :Local Args(0) {
    my ($self, $c) = @_;

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
        if length($password) < 6;

    return fail($c, "The passwords you specified did not match.")
        if $password ne trim $c->req->params->{password2};

    txn_do($c->model('DB')->schema, sub {
        my $user = $c->model('DB::Users')->create(
            { username => $userName
            , fullname => $fullName
            , password => sha1_hex($password)
            , emailaddress => "",
            });
    });

    $c->authenticate({username => $userName, password => $password})
        or error($c, "Unable to authenticate the new user!");

    $c->flash->{successMsg} = "User <tt>$userName</tt> has been created.";
    $c->response->redirect($c->flash->{referer} || $c->uri_for('/'));
}


sub preferences :Local Args(0) {
    my ($self, $c) = @_;
    error($c, "Not implemented.");
}


1;
