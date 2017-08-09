{ pkgs }:

# ------------------------------------------------------------------------------
# This adds a Hydra plugin for users to submit their open source projects
# to the Coverity Scan system for analysis.
#
# First, add a <coverityscan> section to your Hydra config, including the
# access token, project name, and email, and a regex specifying jobs to
# upload:
#
#     <coverityscan>
#       project = testrix
#       jobs    = foobar:.*:coverity.*
#       email   = aseipp@pobox.com
#       token   = ${builtins.readFile ./coverity-token}
#     </coverityscan>
#
# This will upload the scan results for any job whose name matches
# 'coverity.*' in any jobset in the Hydra 'foobar' project, for the
# Coverity Scan project named 'testrix'.
#
# Note that one upload will occur per job matched by the regular
# expression - so be careful with how many builds you upload.
#
# The jobs which are matched by the jobs specification must have a file in
# their output path of the form:
#
#   $out/tarballs/...-cov-int.(xz|lzma|zip|bz2|tgz)
#
# The file must have the 'cov-int' directory produced by `cov-build` in
# the root.
#
# (You can also output something into
# $out/nix-support/hydra-build-products for the Hydra UI.)
#
# This file will be found in the store, and uploaded to the service
# directly using your access credentials. Note the exact extension: don't
# use .tar.xz, only use .xz specifically.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# EmailNotification?
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# S3Backup?
# ------------------------------------------------------------------------------

with { inherit (pkgs) lib; };

rec {
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------

  hasType = ty: value: ty == (builtins.typeOf value);
  isEmail = value: lib.strings.parseEmail value != null;
  checkRegex = lib.strings.checkRegex;
  isHydraInputType = ty: builtins.elem ty [
    "boolean" "string" "path" "nix"
    "bzr" "bzr-checkout" "darcs" "git" "hg" "svn"
    "githubpulls"
  ];
  defaultEmail = "hydra@nixos.org";

  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------

  makeJobsetInput = (
    { type, value, notify ? false }:

    assert hasType "string" type;
    assert hasType "string" value;
    assert hasType "bool"   notify;
    assert isHydraInputType type;

    { inherit type value; emailresponsible = notify; });

  makeJobsetCore = (
    { enable,      # bool
      visible,     # bool
      description, # string
      expression,  # { file = string; input = string; }
      evaluation,  # { keep = int; interval = int; shares = int; }
      email,       # { enable = bool; override = string; }
      inputs       # { * = { type = string; value = string; notify = bool; }; }
    }:

    {
      enabled          = if enable then 1 else 0;
      hidden           = !visible;
      description      = description;
      enableemail      = email.enable;
      emailoverride    = email.override;
      keepnr           = evaluation.keep;
      checkinterval    = evaluation.interval;
      schedulingshares = evaluation.shares;
      inputs           = lib.mapAttrs (_: makeJobsetInput) inputs;
    });

  makeJobset = (
    { enable      ? true,
      visible     ? true,
      description ? "",
      expression  ? { file = "release.nix"; input = "src"; },
      evaluation  ? { keep = 3; interval = 10; shares = 1; },
      email       ? { enable = true; override = defaultEmail; },
      inputs      ? {},
      override    ? (x: x)
    }:

    assert hasType "bool"   enable;
    assert hasType "bool"   visible;
    assert hasType "string" description;
    assert hasType "set"    expression;
    assert hasType "set"    evaluation;
    assert hasType "set"    email;
    assert hasType "set"    inputs;
    assert hasType "lambda" override;

    assert (expression ?      file) && (hasType "string" expression.file);
    assert (expression ?     input) && (hasType "string" expression.input);
    assert (evaluation ?      keep) && (hasType "int"    evaluation.keep);
    assert (evaluation ? intervals) && (hasType "int"    evaluation.intervals);
    assert (evaluation ?    shares) && (hasType "int"    evaluation.shares);
    assert (email      ?    enable) && (hasType "bool"   email.enable);
    assert (email      ?  override) && (isEmail          email.override);

    # `expression.input` must correspond to a key in `inputs`
    assert inputs ? expression.input;

    override (makeJobsetCore {
      inherit enable visible description expression evaluation email inputs;
    }));

  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------

  makeOtherHydraConf = (
    { compress ? true }:

    assert hasType "bool" compress;

    ''
      compress_build_logs = ${if compress then 1 else 0}
    '');

  # ----------------------------------------------------------------------------

  makeCoverityScanStanza = (
    with { defaultScanURL = "http://scan5.coverity.com/cgi-bin/upload.py"; };

    { enable   ? false,         # bool
      project,                  # string
      jobs,                     # string
      email,                    # string
      token,                    # string
      scanURL  ? defaultScanURL # string
    }:

    if !enable then "" else (
      assert hasType "bool"   enable;
      assert hasType "string" project;
      assert hasType "string" jobs;
      assert hasType "string" email;
      assert hasType "string" token;
      assert hasType "string" scanURL;

      assert project != "";
      assert jobs    != "";
      assert email   != "";
      assert token   != "";
      assert scanURL != "";

      assert isEmail email;
      assert checkRegex jobs;

      ''
        <coverityscan>
          project = ${project}
          jobs    = ${jobs}
          email   = ${email}
          token   = ${token}
          scanurl = ${scanURL}
        </coverityscan>
      ''
    ));

  # ----------------------------------------------------------------------------

  # There should only be one <github_authorization> stanza.
  makeGithubAuthStanza = (
    { users # { * = string; }
    }:

    with rec {
      makePair = user: token: "  ${user} = ${token}\n";
      pairs = lib.mapAttrsToList makePair users;
    };

    if pairs == [] then "" else ''
      <github_authorization>
      ${lib.concatStrings pairs}
      </github_authorization>
    '');

  # ----------------------------------------------------------------------------

  # If you authorize with
  #   `curl -H "Authorization: foo" https://api.github.com`
  # then you should set `auth = "foo";`.
  #
  # There can be multiple <githubstatus> stanzas.
  makeGithubStatusStanza = (
    { jobs,                 # string
      inputs        ? [],   # [string]
      exclude       ? true, # bool
      description   ? "",   # string
      context       ? "",   # string
      auth          ? ""    # string
    }:

    with rec {
      containsEOF = string: ((builtins.match ".*EOF.*" string) != null);
      inputPairs = map (i: "  inputs = ${i}\n") inputs;
      heredoc = key: string: (
        assert !(containsEOF string);
        "  ${key} <<EOF\n${string}\nEOF\n");
    };

    assert hasType "string" jobs;
    assert hasType "list"   inputs;
    assert hasType "bool"   exclude;
    assert hasType "string" description;
    assert hasType "string" context;
    assert hasType "string" auth;

    assert checkRegex jobs;

    ''
      <githubstatus>
        jobs = ${jobs}
      ${lib.concatStrings inputPairs}
        excludeBuildFromContext = ${if exclude then 1 else 0}
      ${if description != "" then heredoc "description"   description else ""}
      ${if context     != "" then heredoc "context"       context     else ""}
      ${if auth        != "" then heredoc "authorization" auth        else ""}
      </githubstatus>
    '');

  # ----------------------------------------------------------------------------

  # If `force` is true, always send messages. Otherwise, only send them
  # when the build status changes.
  # There can be multiple <slack> stanzas, each corresponding to a channel.
  makeSlackStanza = (
    { jobs, url, force ? false }:

    assert hasType "string" jobs;
    assert hasType "string" url;
    assert hasType "bool"   force;

    assert checkRegex jobs;

    ''
      <slack>
        jobs  = ${jobs}
        url   = ${url}
        force = ${if force then "true" else "false"}
      </slack>
    '');

  # ----------------------------------------------------------------------------

  # The prefix is prepended to the file name to create the S3 key.
  # There can be multiple <s3backup> stanzas, each corresponding to a bucket.
  makeS3BackupStanza = (
    { name,                # string
      jobs,                # string
      prefix     ? "",     # string
      compressor ? "bzip2" # string
    }:

    with { compressionType = if isNull compressor then "" else compressor; };

    assert hasType "string" name;
    assert hasType "string" jobs;
    assert hasType "string" prefix;
    assert hasType "string" compressionType;

    assert checkRegex jobs;

    assert builtins.elem compressionType ["xz" "bzip2" ""];

    ''
      <s3backup>
        name             = ${name}
        jobs             = ${jobs}
        prefix           = ${prefix}
        compression_type = ${compressionType}
      </s3backup>
    '');

  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
}
