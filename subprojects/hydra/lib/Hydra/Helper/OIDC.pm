package Hydra::Helper::OIDC;

use strict;
use warnings;
use Exporter 'import';
use LWP::UserAgent;
use JSON::MaybeXS qw(decode_json);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url);
use URI;
use Crypt::URandom qw(urandom);
use Crypt::URandom::Token qw(urandom_token);
use File::Slurper qw(read_text);
use ReadonlyX;
use Crypt::JWT qw(decode_jwt);
use String::Compare::ConstantTime qw(equals);
use Hydra::Helper::CatalystUtils qw(error);

our @EXPORT_OK = qw(
    resolveOIDCConfig
);

Readonly::Array our @BASE64URL_CHARS => ('A'..'Z', 'a'..'z', '0'..'9', '-', '_');
Readonly::Array our @PKCE_VERIFIER_CHARS => ('A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~');

# Start a new OIDC login session
sub new {
    my ($class, $c, %args) = @_;
    my $provider_name = $args{provider_name};

    my $conf = $c->config->{oidc}->{provider}->{$provider_name}
        or error($c, "OIDC provider $provider_name is not configured", 404);
    my $session_data = {
        # Per RFC 6749, Section 10.10:
        #   The probability of an attacker guessing generated tokens... SHOULD be less than equal
        #   to 2^(-160)
        # 10 characters of base64 text is well and truly above that.
        state => urandom_token(10, \@BASE64URL_CHARS),
        nonce => urandom_token(10, \@BASE64URL_CHARS),
        # Per RFC 7636 Section 4.1:
        #   high-entropy cryptographic random STRING using the unreserved characters
        #   [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~" ... with a minimum length of 43 characters
        #   and a maximum length of 128 characters.
        code_verifier => urandom_token(43, \@PKCE_VERIFIER_CHARS),
        # It's recommended to not allow redirects to take forever (although RFC 6749 does not
        # mandate or recommend any particular length of time)
        expires_at => time + 600,
        provider_name => $provider_name,
        after => $args{after},
        redirect_uri => $args{redirect_uri},
    };
    $c->session->{oidc} = $session_data;

    return bless {
        c => $c,
        session_data => $session_data,
        provider_name => $provider_name,
        conf =>  $conf,
    }, $class;
}

# Load OIDC login session data from the Catalyst session
sub load {
    my ($class, $c, %args) = @_;
    my $provider_name = $args{provider_name};

    my $conf = $c->config->{oidc}->{provider}->{$provider_name}
        or error($c, "OIDC provider $provider_name is not configured", 404);
    my $session_data = $c->session->{oidc} or error($c, "No OIDC login in progress", 400);
    $session_data->{provider_name} eq $provider_name
        or error($c, "OIDC provider endpoint mismatch", 400);

    return bless {
        c => $c,
        session_data => $session_data,
        provider_name => $provider_name,
        conf =>  $conf,
    }, $class;
}


sub authorizationURL {
    my ($self) = @_;

    my $uri = URI->new($self->{conf}->{authorization_endpoint});
    $uri->query_form(
        response_type => 'code',
        client_id => $self->{conf}->{client_id},
        # This value is saved in the session, so that we can retrieve it when performing the token
        # exchange later
        redirect_uri => $self->{session_data}->{redirect_uri},
        # We need the openid scope to make sure an id token is returned, and email because hydra's
        # DB needs an email. Any extra scopes can be added in configuration (because, for example,
        # the IDP might not be configured to return a hydra_roles claim without explicitly asking
        # for it with a scope)
        scope => do {
            my $base_scope = "openid profile email";
            my $extra_scopes = $self->{conf}->{extra_scopes};
            ($extra_scopes && $extra_scopes ne '') ? "$base_scope $extra_scopes" : $base_scope;
        },
        # RFC 7636 §4.2: code_challenge = BASE64URL-ENCODE(SHA256(code_verifier))
        # MIME::Base64::encode_base64url already omits '=' padding per RFC 4648 §5.
        code_challenge => encode_base64url(sha256($self->{session_data}->{code_verifier})),
        code_challenge_method => 'S256',
        nonce => $self->{session_data}->{nonce},
        state => $self->{session_data}->{state},
    );
    return $uri->as_string;
}

sub validateAuthorizationCode {
    my ($self, $params) = @_;
    my $c = $self->{c};

    # Per RFC 6747 Section 10.12:
    #   The client MUST implement CSRF protection for its redirection URI. This is typically
    #   accomplished by requiring any request sent to the redirection URI to include a value that
    #   binds the request to the user-agent's authenticated state
    error($c, "Invalid state", 400) unless $params->{state};
    error($c, "Invalid state", 400) unless equals($params->{state}, $self->{session_data}->{state});

    # Per RFC 9207 Section 2.4:
    #   Clients that support this specification MUST extract the value of the iss parameter from
    #   authorization responses they receive if the parameter is present... If the value does not
    #   match the expected issuer identifier, clients MUST reject the authorization response
    if ($params->{iss}) {
        error($c, "Invalid issuer", 400) unless $params->{iss} eq $self->{conf}->{issuer};
    }

    # Check if the state hasn't expired in our opinion
    if (time > $self->{session_data}->{expires_at}) {
        error($c, "State expired ($self->{session_data}->{expires_at})", 400);
    }

    # Per RFC 6747 Section 4.1.2.1:
    #   If the resource owner denies the access request or if the request fails for reasons other
    #   than a missing or invalid redirection URI, the authorization server informs the client by
    #   adding the following parameters to the query component of the redirection URI
    if ($params->{error}) {
        my $error_str = $params->{error};
        if ($params->{error_description}) {
          $error_str = "$error_str: $params->{error_description}";
        }
        my $error_code;
        if ($params->{error} =~ /access_denied/) {
            $error_code = 403;
        } elsif ($params->{error} =~ /temporarily_unavailable/) {
            $error_code = 503;
        } else {
            # Everything else indicates something is misconfigured with the OIDC client
            $error_code = 500;
        }
        error($c, "OIDC server rejected authorization: $error_str", $error_code);
    }

    error($c, "Invalid code", 400) unless $params->{code};
    return $params->{code};
};

sub exchangeCodeForToken {
    my ($self, $code) = @_;
    my $c = $self->{c};

    my $ua = $self->make_ua();
    my $req = HTTP::Request::Common::POST($self->{conf}->{token_endpoint}, [
        # Per RFC 6747 Section 4.1.3:
        #   grant_type... Value MUST be set to "authorization_code"
        grant_type => 'authorization_code',
        #   code... The authorization code received from the authorization server
        code => $code,
        #   redirect_uri... REQUIRED, if the "redirect_uri" parameter was included in the
        #   authorization request
        redirect_uri => $self->{session_data}->{redirect_uri},
        # Per RFC 7637 Section 4.5:
        #   In addition to the parameters defined in the OAuth 2.0 Access Token Request, it sends
        #   the following parameter
        code_verifier => $self->{session_data}->{code_verifier},
    ]);
    # Per RFC 6747 Section 2.3.1:
    #   Including the client credentials in the request-body using the two parameters is NOT
    #   RECOMMENDEDand SHOULD be limited to clients unable to directly utilize the HTTP Basic
    #   authentication scheme
    # So we should not pass client_id & client_secret in the body, but rather in an auth header
    $req->authorization_basic($self->{conf}->{client_id}, $self->{conf}->{client_secret});
    my $res = $ua->request($req);

    my $res_json = eval {
        decode_json($res->decoded_content);
    };
    if ($@) {
        # The response was not JSON, probably this is like a load balancer returning a 500
        # page or some such. So check the status code when deciding what to return here.
        if (not $res->is_success) {
            error($c, "OIDC token endpoint returned status " . $res->status_line, 500);
        } else {
            error($c, "OIDC token endpoint did not return valid JSON: $@", 500);
        }
    }
    if ($res_json->{error}) {
        my $error_str = $res_json->{error};
        if ($res_json->{error_description}) {
            $error_str = "$error_str: $res_json->{error_description}";
        }
        # All of the possibilities here are a misconfiguration
        error($c, "OIDC token endpoint returned error: $error_str", 500);
    }
    # Catch HTTP errors that returned valid JSON without an 'error' field
    # (e.g. a reverse proxy returning a JSON 502 page).
    if (not $res->is_success) {
        error($c, "OIDC token endpoint returned status " . $res->status_line, 500);
    }

    error($c, "OIDC token endpoint did not return an id token", 400) unless $res_json->{id_token};

    return $res_json->{id_token};
}

sub validateToken {
    my ($self, $token) = @_;
    my $c = $self->{c};

    # Crypt::JWT handles the standard ID token validation required by OIDC
    # Core 1.0 §3.1.3.7 for us: signature verification against JWKS, issuer
    # match, audience match, exp/nbf time checks, and rejection of alg=none.
    # It does NOT verify the nonce (OIDC-specific) or sub presence, which we
    # check separately below.
    my $claims;
    # Try twice: first with cached JWKS, then refreshed if the key ID is
    # unknown (OIDC Core §10.1.1: re-fetch jwks_uri on unfamiliar kid).
    foreach my $force_refresh (0, 1) {
        my $jwks = $self->JWKS(force => $force_refresh);
        $claims = eval {
            decode_jwt(
                token      => $token,
                kid_keys   => $jwks,
                verify_iss => sub { $_[0] eq $self->{conf}->{issuer} },
                verify_aud => sub { $_[0] eq $self->{conf}->{client_id} },
                verify_exp => 1,
                verify_nbf => 1,
            );
        };
        last if $claims;
        next if $@ =~ /kid_keys lookup failed/ && !$force_refresh;
        error($c, "OIDC token validation failed: $@", 401);
    }

    # Nonce binds the token to our authorization request (replay protection).
    $claims->{nonce} or error($c, "No nonce claim in OIDC token", 400);
    equals($claims->{nonce}, $self->{session_data}->{nonce})
        or error($c, "Nonce mismatch", 403);

    # We use `sub` as the stable user identifier; it's REQUIRED by OIDC but
    # be defensive anyway.
    $claims->{sub} or error($c, "No sub claim in OIDC token", 400);

    return $claims;
}

sub JWKS {
    my ($self, %args) = @_;
    my $c = $self->{c};
    my $provider_name = $self->{session_data}->{provider_name};
    my $jwks_uri = $self->{conf}->{jwks_uri};
    my $cache_key = "oidc.$provider_name.jwks";

    if (!$args{force}) {
        my $jwks = $c->cache_get($cache_key);
        return $jwks if $jwks;
    }

    my $ua = $self->make_ua();
    my $res = $ua->get($jwks_uri);
    if (not $res->is_success) {
        error($c, "Failed fetching OIDC JWKS endpoint $jwks_uri: ". $res->status_line, 500);
    }
    my $res_json = eval {
        decode_json($res->decoded_content);
    };
    if ($@) {
        error($c, "OIDC JWKS endpoint returned invalid JSON: $@", 500);
    }

    $c->cache_set($cache_key, $res_json, expires => 60);
    return $res_json;
}

sub clear_session {
    my ($self) = @_;
    my $c = $self->{c};

    # Clears the session out of the session store, but does NOT clear $self->session_data;
    # this is so we can call $self->after() later in the request to redirect.
    $c->session->{oidc} = undef;
}

sub after {
    my ($self) = @_;
    return $self->{session_data}->{after};
}

sub make_ua {
    my ($self) = @_;
    return _make_ua($self->{conf});
}

sub _make_ua {
    my ($conf) = @_;

    my $ua = LWP::UserAgent->new(timeout => 10);
    if (defined $conf->{ca_file}) {
        $ua->ssl_opts(SSL_ca_file => $conf->{ca_file});
    }
    return $ua;
}

# Run at startup to perform a couple of jobs. Expects to receive $c->config->{oidc} and mutates it
# to perform two tasks:
#  * If discovery_url is set, fetch that JSON document & set other config parameters from it
#  * If client_secret_file is set, read the file & set client_secret from it
sub resolveOIDCConfig {
    my ($oidc_config) = @_;

    return unless $oidc_config;
    return unless $oidc_config->{provider};

    foreach my $provider_name (keys %{$oidc_config->{provider}}) {
        my $provider = $oidc_config->{provider}{$provider_name};

        # Load secrets from file
        if ($provider->{client_secret_file}) {
            my $client_secret = read_text($provider->{client_secret_file});
            $client_secret =~ s/^\s+|\s+$//g;  # Trim whitespace
            $provider->{client_secret} = $client_secret;
        }

        # Load configuration from .well-known/oidc-configuration endpoint
        if ($provider->{discovery_url}) {
            my $discovery = eval {
                getOIDCDiscovery($provider);
            };
            if ($@) {
                die "Failed to resolve OIDC discovery for provider '$provider_name': $@";
            }

            # Materialize discovery endpoints into config (only if not already set)
            $provider->{authorization_endpoint} //= $discovery->{authorization_endpoint};
            $provider->{token_endpoint} //= $discovery->{token_endpoint};
            $provider->{jwks_uri} //= $discovery->{jwks_uri};
            $provider->{issuer} //= $discovery->{issuer};
            # Optional: RP-Initiated Logout (OpenID Connect Session Management)
            $provider->{end_session_endpoint} //= $discovery->{end_session_endpoint};
        }

        # Validate that all required endpoints are present (either from discovery or manual config)
        for my $field (qw(authorization_endpoint token_endpoint jwks_uri issuer)) {
            $provider->{$field}
                or die "OIDC provider '$provider_name' is missing '$field' "
                     . "(set discovery_url or configure it explicitly)\n";
        }
        $provider->{client_secret}
            or die "OIDC provider '$provider_name' must have client_secret or client_secret_file\n";
    }
}

sub getOIDCDiscovery {
    my ($conf) = @_;

    my $ua = _make_ua($conf);
    my $res = $ua->get($conf->{discovery_url});
    die "Discovery request to $conf->{discovery_url} failed: " . $res->status_line
        unless $res->is_success;

    my $doc = eval { decode_json($res->decoded_content) };
    die "Discovery response is not valid JSON: $@" if $@;

    # Validate required fields per OIDC spec
    die "Missing 'issuer' in discovery document" unless $doc->{issuer};
    die "Missing 'authorization_endpoint' in discovery document" unless $doc->{authorization_endpoint};
    die "Missing 'token_endpoint' in discovery document" unless $doc->{token_endpoint};
    die "Missing 'jwks_uri' in discovery document" unless $doc->{jwks_uri};

    return $doc;
}

1;
