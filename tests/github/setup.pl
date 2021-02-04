use LWP::UserAgent;
use JSON;
use Test::Simple;

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

sub request_json {
    my ($opts) = @_;
    my $req = HTTP::Request->new;
    $req->method($opts->{method} or "GET");
    $req->uri("http://localhost:3000$opts->{uri}");
    $req->header(Accept => "application/json");
    $req->header(Referer => "http://localhost:3000/") if $opts->{method} eq "POST";
    $req->content(encode_json($opts->{data})) if defined $opts->{data};
    my $res = $ua->request($req);
    print $res->as_string();
    return $res;
}

my $result = request_json({
  uri => "/login",
  method => "POST",
  data => {
    username => "root",
    password => "foobar"
  }
});

$result = request_json({
  uri => '/project/sample',
  method => 'PUT',
  data => {
    displayname => "Sample",
    enabled => "1",
    visible => "1",
  }
});

$result = request_json({
  uri => '/jobset/sample/default',
  method => 'PUT',
  data => {
    nixexprpath => "default.nix",
    nixexprinput => "src",
    inputs => {
      "src" => {
        type => "git",
        value => "file:///run/jobset"
      }
    },
    enabled => "0", # manual eval only
    visible => "1",
    checkinterval => "5",
    keepnr => 1
  }
});

system("hydra-eval-jobset sample default");
