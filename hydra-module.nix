{ config, pkgs, lib, ... }:

# ------------------------------------------------------------------------------
# FIXME: send this stuff upstream to nixpkgs
# vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv

with rec {
  inherit (lib) mkIf mkOption;

  forceWHNF = x: builtins.seq x x;
  forceDeep = x: builtins.deepSeq x x;

  strings = lib.strings // {
    intercalate = str: list: lib.concatStrings (lib.intersperse str list);
  };

  lists = lib.lists // (
    with {
      foldToFold1 = fold: (f: list: (
        assert builtins.length list > 0;
        with {
          mlist = builtins.map (x: { v = x; }) list;
          merge = a: b: (
            if a != null
            then (if b != null then { v = f a.v b.v; } else a)
            else (if b != null then b                  else null));
        };
        (fold merge null mlist).value));
    };

    {
      foldr   = lib.lists.fold;
      foldr1  = foldToFold1 lists.foldr;
      foldl   = lib.lists.foldl;
      foldl1  = foldToFold1 lists.foldl;
      foldl'  = lib.lists.foldl';
      foldl1' = foldToFold1 lists.foldl';
    });

  types = lib.types // {
    oneof = list: (
      assert lib.isList list;
      # assert lib.all lib.isOptionType list;

      if lib.length list > 0
        then lists.foldr1 lib.types.either list
        else throw "lib.types.oneof: empty list");

    matching = rx: type: (lib.types.addCheck type (str:
      assert builtins.isString str;
      (builtins.match "^${rx}$" str) != null));
  };
};

# ∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧
# ------------------------------------------------------------------------------

with rec {
  cfg = config.services.hydra-dev;

  baseDir = "/var/lib/hydra";

  hydraConf = pkgs.writeScript "hydra.conf" cfg.extraConfig;

  hydraEnv = {
    HYDRA_DBI = cfg.dbi;
    HYDRA_CONFIG = "${baseDir}/hydra.conf";
    HYDRA_DATA = "${baseDir}";
  };

  env = {
    NIX_REMOTE = "daemon";
    PGPASSFILE = "${baseDir}/pgpass";
    NIX_REMOTE_SYSTEMS = concatStringsSep ":" cfg.buildMachinesFiles;
  } // optionalAttrs (cfg.smtpHost != null) {
    EMAIL_SENDER_TRANSPORT = "SMTP";
    EMAIL_SENDER_TRANSPORT_host = cfg.smtpHost;
  } // hydraEnv // cfg.extraEnv;

  serverEnv = env // {
    HYDRA_TRACKER = cfg.tracker;
    COLUMNS = "80";
    PGPASSFILE = "${baseDir}/pgpass-www"; # grrr
  } // (optionalAttrs cfg.debugServer { DBIC_TRACE = "1"; });

  localDB = "dbi:Pg:dbname=hydra;user=hydra;";

  haveLocalDB = cfg.dbi == localDB;

  hydraExe = name: "${cfg.package}/bin/${name}";

  mkLink = url: contents: "<link xlink:href=\"${url}\">${contents}</link>";

  links = {
    googleOAuthDocs =
      "https://developers.google.com/identity/sign-in/web/devconsole-project";
    catalystPreforkDocs =
      "http://search.cpan.org/~agrundma/Catalyst-Engine-HTTP-Prefork/lib/Catalyst/Engine/HTTP/Prefork.pm";
    pixz =
      "https://github.com/vasi/pixz";
    githubStatusDocs =
      "https://developer.github.com/v3/repos/statuses";
    slackWebhook =
      "https://my.slack.com/services/new/incoming-webhook";
  };
};

{
  ###### interface

  options = {

    services.hydra-dev = rec {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run Hydra services.
        '';
      };

      dbi = mkOption {
        type = types.str;
        default = localDB;
        example = "dbi:Pg:dbname=hydra;host=postgres.example.org;user=foo;";
        description = ''
          The DBI string for Hydra database connection.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.hydra;
        description = "The Hydra package.";
      };

      hydraURL = mkOption {
        type = types.str;
        description = ''
          The base URL for the Hydra webserver instance.
          Used for links in emails.
        '';
      };

      listenHost = mkOption {
        type = types.str;
        default = "*";
        example = "localhost";
        description = ''
          The hostname or address to listen on.
          If <literal>*</literal> is given, listen on all interfaces.
        '';
      };

      port = mkOption {
        type = types.int;
        default = 3000;
        description = ''
          TCP port the web server should listen to.
        '';
      };

      minimumDiskFree = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the queue
          runner should run or not.
        '';
      };

      minimumDiskFreeEvaluator = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the evaluator
          should run or not.
        '';
      };

      notificationSender = mkOption {
        type = types.str;
        description = ''
          Sender email address used for email notifications.
        '';
      };

      smtpHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = ["localhost"];
        description = ''
          Hostname of the SMTP server to use to send email.
        '';
      };

      tracker = mkOption {
        type = types.str;
        default = "";
        description = ''
          Piece of HTML that is included on all pages.
        '';
      };

      logo = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the logo of your Hydra instance.
        '';
      };

      debugServer = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to run the server in debug mode.";
      };

      extraConfig = mkOption {
        type = types.lines;
        description = "Extra lines for the Hydra configuration.";
      };

      extraEnv = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Extra environment variables for Hydra.";
      };

      gcRootsDir = mkOption {
        type = types.path;
        default = "/nix/var/nix/gcroots/hydra";
        description = "Directory that holds Hydra garbage collector roots.";
      };

      buildMachinesFiles = mkOption {
        type = types.listOf types.path;
        default = ["/etc/nix/machines"];
        example = ["/etc/nix/machines" "/var/lib/hydra/provisioner/machines"];
        description = "List of files containing build machines.";
      };

      useSubstitutes = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use binary caches for downloading store paths. Note that
          binary substitutions trigger a potentially large number of additional
          HTTP requests that slow down the queue monitor thread significantly.
          Also, this Hydra instance will serve those downloaded store paths to
          its users with its own signature attached as if it had built them
          itself, so don't enable this feature unless your active binary caches
          are absolute trustworthy.
        '';
      };

      googleClientID = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "35009a79-1a05-49d7-b876-2b884d0f825b";
        description = ''
          The Google API client ID to use in the Hydra Google OAuth login.

          More information is available ${mkLink links.googleOAuthDocs "here"}.
        '';
      };

      private = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = ''
          If set to <literal>true</literal>, this option will make this Hydra
          "private". This means that a login will be required to see the
          projects associated with this Hydra instance.

          Note that the Hydra declarative user and project options may not work
          in combination with this option, since the Hydra API is disabled in
          private mode. This issue is tracked
          ${mkLink "https://github.com/NixOS/hydra/issues/503" "here"}.
        '';
      };

      maxServers = mkOption {
        type = types.int;
        default = 25;
        example = 50;
        description = ''
          The maximum number of child servers to start, as described in the
          ${mkLink (links.catalystPreforkDocs + "#max_servers")
                   "Catalyst::Engine::HTTP::Prefork documentation"}.
        '';
      };

      maxSpareServers = mkOption {
        type = types.int;
        default = 5;
        example = 10;
        description = ''
          The maximum number of servers to have waiting for requests, as
          described in the
          ${mkLink (links.catalystPreforkDocs + "#max_spare_servers")
                   "Catalyst::Engine::HTTP::Prefork documentation"}.
        '';
      };

      maxRequests = mkOption {
        type = types.int;
        default = 100;
        example = 1000;
        description = ''
          FIXME: lol
          The number of requests after which a child will be restarted, as
          described in the
          ${mkLink (links.catalystPreforkDocs + "#max_requests")
                   "Catalyst::Engine::HTTP::Prefork documentation"}.
        '';
      };

      maxOutputSize = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 4294967296;
        description = ''
          The maximum size of a Hydra build output.
        '';
      };

      compressCores = mkOption {
        type = types.int;
        default = 0;
        example = 4;
        description = ''
          The number of cores to use when compressing NAR files using
          ${mkLink links.pixz "pixz"}.

          If the given number is <literal>0</literal>, then the number of cores
          on the system will be used.

          This option corresponds to the
          <option>-p</option> <replaceable>CPUS</replaceable>
          command line option of <command>pixz</command>.
        '';
      };

      storeURI = mkOption {
        type = (
          with rec {
            rx = {
              scheme   = "(file|https|s3|ssh)";
              user     = "(([^@]*)[@])";
              host     = "([^/]*)"; # not very specific
              port     = "([:]([0-9]{1,4}|[1-5][0-9]{4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-6])))))";
              path     = "([/][^?]*)";
              param    = "(([^=]*)[=]([^&]*))";
              query    = "([?]((${rx.param}[&])*${rx.param}))";
              anyURI   = with rx; "${scheme}://${user}?${host}?${port}?${path}?${query}?";
              storeURI = "(local|daemon|auto|${rx.anyURI})";
            };
          };
          types.nullOr (types.matching rx.storeURI types.str));
        default = null;
        # example = …;
        description = ''
          This specifies the Nix store that Hydra should use, as a store URI.

          This can take one of the following forms:

          <itemizedlist>
             <listitem>
               <literal>local</literal>:
               the Nix store in <literal>/nix/store</literal> and the database
               in <literal>/nix/var/nix/db</literal>, accessed directly.
             </listitem>
             <listitem>
               <literal>daemon</literal>:
               the Nix store accessed via a Unix domain socket connection to
               the <literal>nix-daemon</literal>.
             </listitem>
             <listitem>
               <literal>auto</literal>:
               depending on whether the user has write access to the local
               Nix store, this will be equivalent to either
               <literal>local</literal> or <literal>daemon</literal>.
             </listitem>
             <listitem>
               <literal>file://<replaceable>path</replaceable></literal>:
               a binary cache stored in <replaceable>path</replaceable>.
             </listitem>
             <listitem>
               <literal>https://<replaceable>path</replaceable></literal>:
               a binary cache accessed via HTTP over TLS.
             </listitem>
             <listitem>
               <literal>s3://<replaceable>path</replaceable></literal>:
               a writable binary cache stored on Amazon S3.
             </listitem>
             <listitem>
               <literal>ssh://[<replaceable>user</replaceable>@]<replaceable>host</replaceable></literal>:
               a remote Nix store accessed by running
               <command>nix-store</command> <option>--serve</option> via SSH.
             </listitem>
           </itemizedlist>

           Any of these store URIs can be suffixed by a parameter string, e.g.:
           <literal><![CDATA[https://example.com?foo=bar&baz=quux]]></literal>.

           In particular, the <literal>secret-key</literal> parameter is useful
           for specifying a binary cache signing key file.

           The parameters that can be passed as part of a Nix store URI are not
           currently documented, but if you want to find them it is useful to
           look at all the classes in the Nix <literal>libstore</literal> API
           that are subclasses of the <literal>Store</literal> class. These
           classes represent handlers for different kinds of Nix store URIs,
           and whenever they have a field of type <literal>Setting</literal>
           or <literal>PathSetting</literal>, it corresponds to a store URI
           parameter key.
        '';
        # FIXME: ensure that the above is actually true
        # https://github.com/NixOS/nix/blob/2fd8f8bb99a2832b3684878c020ba47322e79332/src/libstore/store-api.hh#L693-L718
      };

      plugins.coverity = mkOption {
        type = types.listOf (types.submodule {
          options = {
            jobs = mkOption {
              type = types.str; # regex
              example = "foo:bar:.*";
              description = ''
                This option defines a regular expression selecting the jobs for
                which the scan results should be uploaded. Note that one upload
                will occur per job matched by this regular expression, so be
                careful with how many builds you upload.

                The format is, as usual, <literal>project:jobset:job</literal>.
              '';
            };

            project = mkOption {
              type = types.str;
              default = [];
              # example = …;
              description = ''
                The name of a Coverity Scan project to which scan results will
                be uploaded.
              '';
            };

            email = mkOption {
              type = types.str;
              example = "foobar@example.com";
              description = ''
                This is an email address to which notification of build analysis
                results will be sent.
              '';
            };

            token = mkOption {
              type = types.str;
              # example = …;
              description = ''
                The Coverity Scan project token to use when uploading.
              '';
            };

            scanURL = mkOption {
              type = types.str;
              default = "http://scan5.coverity.com/cgi-bin/upload.py";
              description = ''
                The URL to use when uploading scan results to Coverity.
                The default should suffice in most normal use cases, though you
                may need this if you run a private Coverity instance.
              '';
            };
          };
        });
        default = [];
        # example = …;
        description = ''
          Options related to the Hydra Coverity Scan plugin.

          Each job matched by the <literal>jobs</literal> specification must
          have a file in its output path of the form
          <literal>$out/tarballs/…-cov-int.(xz|lzma|zip|bz2|tgz)</literal>.

          The file must have the <literal>cov-int</literal> produced by
          <command>cov-build</command> in the root.

          Note that that list of extensions is exact: the file should be named
          <literal>…-cov-int.xz</literal>, not the more obvious
          <literal>…-cov-int.tar.xz</literal>.
        '';
      };

      plugins.github = {
        auth = mkOption {
          type = types.attrsOf types.str;
          default = {};
          example = { foobar = "fd3t43ijdx"; };
          description = ''
            A map from usernames to GitHub authorization tokens, as strings.
            The values specified here are mainly used as a fallback option
            when other GitHub-related options don't specify a token.
          '';
        };

        status = mkOption {
          type = types.listOf (types.submodule {
            options = {
              jobs = mkOption {
                type = types.str; # regex
                example = "foo:bar:.*";
                description = ''
                  A regular expression that is matched against a string of the
                  form <literal><replaceable>project</replaceable>:<replaceable>jobset</replaceable>:<replaceable>job</replaceable></literal>.

                  If a job matches this regular expression, GitHub Status API
                  calls will be made against all of the GitHub repositories
                  computed from the Hydra jobset inputs corresponding to the
                  <literal>services.hydra.plugins.github.inputs</literal>
                  variable.
                '';
              };

              inputs = mkOption {
                type = types.listOf types.str;
                example = ["src"];
                description = ''
                  A list of input names, which must correspond to Git repository
                  Hydra inputs on jobs matching the <literal>jobs</literal> regex.
                  These Git repository URLs are used to compute the GitHub Status
                  API calls.
                '';
                # FIXME: wait, should it actually be a githubpulls input?
              };

              exclude = mkOption {
                type = types.bool;
                default = true;
                example = false;
                description = ''
                  This option determines whether the build ID should be omitted
                  from the status sent to GitHub.
                '';
              };

              description = mkOption {
                type = types.nullOr types.str;
                default = null;
                # example = …;
                description = ''
                  A short description of the status.
                  Must be shorter than 1024 bytes.
                  If <literal>null</literal>, defaults to an empty string.
                '';
              };

              context = mkOption {
                type = types.nullOr types.str;
                default = null;
                # example = …;
                description = ''
                  The string to use in the <literal>context</literal> field of a
                  GitHub Status API call, as described in
                  ${mkLink links.githubStatusDocs "this documentation"}.

                  If <literal>null</literal>, defaults to an empty string.
                '';
              };

              auth = mkOption {
                type = types.nullOr types.str;
                default = null;
                # example = …;
                description = ''
                  A GitHub authorization token
                '';
              };
            };
          });
          default = [];
          # example = …;
          description = ''
            Options related to the Hydra GitHub status plugin.
          '';
        };
      };

      plugins.slack = {
        notifications = mkOption {
          type = types.listOf (types.submodule {
            options = {
              jobs = mkOption {
                type = types.str; # regex
                example = "foo:bar:.*";
                description = ''
                  A regular expression that is matched against a string of the
                  form <literal><replaceable>project</replaceable>:<replaceable>jobset</replaceable>:<replaceable>job</replaceable></literal>.

                  Whenever a job matching the provided regular expression is
                  created, a Slack notification will be triggered.
                '';
              };

              url = mkOption {
                type = types.str;
                example = "https://hooks.slack.com/services/XXXXXXXXX/YYYYYYYYY/ZZZZZZZZZZZZZZZZZZZZZZZZ";
                description = ''
                  The URL of a Slack Incoming Webhook; you can create a Slack
                  webhook with ${mkLink links.slackWebhook "this link"}
                  (replace <literal>my.slack.com</literal> with your team name
                  if that link doesn't work properly).
                '';
              };

              force = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = ''
                  FIXME: doc
                '';
              };
            };
          });
          default = [];
          # example = …;
          description = ''
            FIXME: doc
          '';
        };
      };

      plugins.s3backup = {
        buckets = mkOption {
          type = types.attrsOf (types.submodule {
            options = {
              jobs = mkOption {
                type = types.str; # regex
                example = "foo:bar:.*";
                description = ''
                  FIXME: doc
                '';
              };

              prefix = mkOption {
                type = types.nullOr types.str;
                default = null;
                # example = …;
                description = ''
                  FIXME: doc
                '';
              };

              compressor = mkOption {
                type = types.enum [null "xz" "bzip2"];
                default = "bzip2";
                example = "xz";
                description = ''
                  FIXME: doc
                '';
              };
            };
          });
          default = {};
          # example = …;
          description = ''
            FIXME: doc
          '';
        };
      };

      projects = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              # example = …;
              description = ''
                FIXME: doc
              '';
            };

            visible = mkOption {
              type = types.bool;
              default = true;
              # example = …;
              description = ''
                FIXME: doc
              '';
            };

            displayName = mkOption {
              type = types.nullOr types.str;
              default = null;
              # example = …;
              description = ''
                FIXME: doc
              '';
            };

            description = mkOption {
              type = types.nullOr types.str;
              default = null;
              # example = …;
              description = ''
                FIXME: doc
              '';
            };

            homepage = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "https://github.com/NixOS/nixpkgs";
              description = ''
                FIXME: doc
              '';
            };

            owner = mkOption {
              # FIXME: should check that this is a valid user
              type = types.nullOr types.str;
              example = "admin";
              description = ''
                FIXME: doc
              '';
            };

            jobsets = mkOption {
              type = types.attrsOf (types.submodule {
                options = {
                  enable = mkOption {
                    type = types.bool;
                    default = true;
                    # example = …;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  visible = mkOption {
                    type = types.bool;
                    default = true;
                    # example = …;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  description = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    # example = …;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  expression.file = mkOption {
                    type = types.str;
                    example = "release.nix";
                    description = ''
                      FIXME: doc
                    '';
                  };

                  expression.input = mkOption {
                    # FIXME: should check that this is one of the inputs
                    type = types.str;
                    example = "src";
                    description = ''
                      FIXME: doc
                    '';
                  };

                  evaluation.keep = mkOption {
                    type = types.int;
                    example = 3;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  evaluation.interval = mkOption {
                    type = types.int;
                    example = 10;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  evaluation.shares = mkOption {
                    type = types.int;
                    example = 1;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  email.enable = mkOption {
                    type = types.bool;
                    default = true;
                    # example = …;
                    description = ''
                      FIXME: doc
                    '';
                  };

                  email.override = mkOption {
                    type = types.str;
                    example = "foobar@example.com";
                    description = ''
                      FIXME: doc
                    '';
                  };

                  inputs = mkOption {
                    type = types.attrsOf (types.submodule {
                      options = {
                        type = mkOption {
                          type = types.enum [
                            "boolean"
                            "string"
                            "path"
                            "nix"
                            "bzr"
                            "bzr-checkout"
                            "darcs"
                            "git"
                            "hg"
                            "svn"
                            "githubpulls"
                          ];
                          description = ''
                            FIXME: doc
                          '';
                        };

                        value = mkOption {
                          type = types.str;
                          description = ''
                            FIXME: doc
                          '';
                        };

                        notify = mkOption {
                          type = types.bool;
                          default = false;
                          example = true;
                          description = ''
                            FIXME: doc
                          '';
                        };
                      };
                    });
                    default = {};
                    example = {
                      src = {
                        type = "git";
                        value = "https://github.com/NixOS/nixpkgs.git";
                        notify = false;
                      };

                      pullsJSON = {
                        type = "githubpulls";
                        value = "NixOS nixpkgs";
                      };
                    };
                    description = ''
                      FIXME: doc
                    '';
                  };
                };
              });
              default = {};
              # example = …;
              description = ''
                FIXME: doc
              '';
            };

            # Project data:
            # - enabled?
            # - visible?
            # - display name
            # - description
            # - homepage
            # - owner
            # - declarative spec file
            # - declarative input type
            #   - type:  hydra input
            #            | previous hydra build
            #            | previous hydra build (same system)
            #            | previous hydra eval
            #   - value: string
          };
        });
        default = {};
        # example = …;
        description = ''
          FIXME: doc
        '';
      };

    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    users.extraGroups.hydra = {};

    users.extraUsers.hydra = {
      description     = "Hydra";
      group           = "hydra";
      createHome      = true;
      home            = baseDir;
      useDefaultShell = true;
    };

    users.extraUsers.hydra-queue-runner = {
      description     = "Hydra queue runner";
      group           = "hydra";
      useDefaultShell = true;
      home            = "${baseDir}/queue-runner"; # <-- keeps SSH happy
    };

    users.extraUsers.hydra-www = {
      description     = "Hydra web server";
      group           = "hydra";
      useDefaultShell = true;
    };

    nix.trustedUsers = ["hydra-queue-runner"];

    services.hydra-dev.package = (
      mkDefault ((import ./release.nix {}).build.x86_64-linux));

    services.hydra-dev.extraConfig = ''
      using_frontend_proxy = 1
      base_uri = ${cfg.hydraURL}
      notification_sender = ${cfg.notificationSender}
      max_servers = ${toString cfg.maxServers}
      compress_num_threads = ${toString cfg.compressCores}
      ${optionalString (cfg.logo != null) "hydra_logo = ${cfg.logo}"}
      gc_roots_dir = ${cfg.gcRootsDir}
      use-substitutes = ${if cfg.useSubstitutes then "1" else "0"}
      ${optionalString (cfg.googleClientID != null) ''
        enable_google_login = 1
        google_client_id = ${cfg.googleClientID}
      ''}
      private = ${if cfg.private then "1" else "0"}
      ${optionalString (cfg.logPrefix != null)
        "log_prefix = ${cfg.logPrefix}"}
      ${optionalString (cfg.maxOutputSize != null)
        "max_output_size = ${cfg.maxOutputSize}"}
    '';

    # FIXME: add/investigate all of these:
    # - compress_build_logs = …
    # - compression_type = …
    # - allowed_domains = …
    # - max_db_connections = int
    # - nar_buffer_size = int
    # - max_output_size = int
    # - upload_logs_to_binary_cache = bool
    # - xxx-jobset-repeats = string
    # - max-concurrent-notifications = int

    environment.systemPackages = [cfg.package];

    environment.variables = hydraEnv;

    nix.extraOptions = ''
      gc-keep-outputs = true
      gc-keep-derivations = true

      # The default (`true') slows Nix down a lot since the build farm
      # has so many GC roots.
      gc-check-reachability = false
    '';

    systemd.services.hydra-init = {
      wantedBy = ["multi-user.target"];
      requires = optional haveLocalDB "postgresql.service";
      after = optional haveLocalDB "postgresql.service";
      environment = env;
      preStart = ''
        mkdir -p ${baseDir}
        chown hydra.hydra ${baseDir}
        chmod 0750 ${baseDir}

        ln -sf ${hydraConf} ${baseDir}/hydra.conf

        mkdir -m 0700 -p ${baseDir}/www
        chown hydra-www.hydra ${baseDir}/www

        mkdir -m 0700 -p ${baseDir}/queue-runner
        mkdir -m 0750 -p ${baseDir}/build-logs
        chown hydra-queue-runner.hydra ${baseDir}/queue-runner
        chown hydra-queue-runner.hydra ${baseDir}/build-logs

        ${optionalString haveLocalDB ''
          if ! [ -e ${baseDir}/.db-created ]; then
              ${config.services.postgresql.package}/bin/createuser hydra
              ${config.services.postgresql.package}/bin/createdb -O hydra hydra
              touch ${baseDir}/.db-created
          fi
        ''}

        if [ ! -e ${cfg.gcRootsDir} ]; then
            # Move legacy roots directory.
            if [ -e /nix/var/nix/gcroots/per-user/hydra/hydra-roots ]; then
                mv /nix/var/nix/gcroots/per-user/hydra/hydra-roots \
                   ${cfg.gcRootsDir}
            fi

            mkdir -p ${cfg.gcRootsDir}
        fi

        # Move legacy hydra-www roots.
        if [ -e /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots ]; then
            find /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots/ -type f \
                | xargs -r mv -f -t ${cfg.gcRootsDir}/
            rmdir /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots
        fi

        chown hydra.hydra ${cfg.gcRootsDir}
        chmod 2775 ${cfg.gcRootsDir}
      '';

      serviceConfig = {
        ExecStart            = hydraExe "hydra-init";
        PermissionsStartOnly = true;
        User                 = "hydra";
        Type                 = "oneshot";
        RemainAfterExit      = true;
      };
    };

    systemd.services.hydra-server = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      after = ["hydra-init.service"];
      environment = serverEnv;
      restartTriggers = [hydraConf];
      serviceConfig = {
        ExecStart = ("@${hydraExe "hydra-server"} hydra-server " + (
          lib.concatStrings (lib.intersperse " " (filter builtins.isString [
            "-f"
            "-h '${cfg.listenHost}'"
            "-p ${toString cfg.port}"
            "--max_spare_servers ${toString cfg.maxSpareServers}"
            "--max_servers ${toString cfg.maxServers}"
            "--max_requests ${toString cfg.maxRequests}"
            (if cfg.debugServer then "-d" else null)
          ]))));
        User                 = "hydra-www";
        PermissionsStartOnly = true;
        Restart              = "always";
      };
    };

    systemd.services.hydra-queue-runner = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      after = ["hydra-init.service" "network.target"];
      path = [
        cfg.package
        pkgs.nettools
        pkgs.openssh
        pkgs.bzip2
        config.nix.package
      ];
      restartTriggers = [hydraConf];
      environment = env // {
        PGPASSFILE = "${baseDir}/pgpass-queue-runner"; # grrr
        IN_SYSTEMD = "1"; # to get log severity levels
      };
      serviceConfig = {
        ExecStart        = "@${hydraExe "hydra-queue-runner"} hydra-queue-runner -v";
        ExecStopPost     = "${hydraExe "hydra-queue-runner"} --unlock";
        User             = "hydra-queue-runner";
        Restart          = "always";
        LimitCORE        = "infinity"; # <-- ensure we can get core dumps.
        WorkingDirectory = "${baseDir}/queue-runner";
      };
    };

    systemd.services.hydra-evaluator = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      restartTriggers = [hydraConf];
      after = ["hydra-init.service" "network.target"];
      path = with pkgs; [nettools cfg.package jq];
      environment = env;
      serviceConfig = {
        ExecStart        = "@${hydraExe "hydra-evaluator"} hydra-evaluator";
        ExecStopPost     = "${hydraExe "hydra-evaluator"} --unlock";
        User             = "hydra";
        Restart          = "always";
        WorkingDirectory = baseDir;
      };
    };

    systemd.services.hydra-update-gc-roots = {
      requires = ["hydra-init.service"];
      after = ["hydra-init.service"];
      environment = env;
      serviceConfig = {
        ExecStart = "@${hydraExe "hydra-update-gc-roots"} hydra-update-gc-roots";
        User      = "hydra";
      };
      startAt = "2,14:15";
    };

    systemd.services.hydra-send-stats = {
      wantedBy = ["multi-user.target"];
      after = ["hydra-init.service"];
      environment = env;
      serviceConfig = {
        ExecStart = "@${hydraExe "hydra-send-stats"} hydra-send-stats";
        User      = "hydra";
      };
    };

    # If there is less than a certain amount of free disk space, stop
    # the queue/evaluator to prevent builds from failing or aborting.
    systemd.services.hydra-check-space = {
      script = ''
        FREE_BLOCKS="$(stat -f -c '%a' /nix/store)"
        BLOCK_SIZE="$(stat -f -c '%S' /nix/store)"
        FREE_BYTES="$((FREE_BLOCKS * BLOCK_SIZE))"
        QUEUE_MIN_FREE_GB="${toString cfg.minimumDiskFree}"
        QUEUE_MIN_FREE_BYTES="$((QUEUE_MIN_FREE_GB * 1024**3))"
        EVAL_MIN_FREE_GB="${toString cfg.minimumDiskFreeEvaluator}"
        EVAL_MIN_FREE_BYTES="$((EVAL_MIN_FREE_GB * 1024**3))"

        if (( FREE_BYTES < QUEUE_MIN_FREE_BYTES )); then
            echo "stopping Hydra queue runner due to lack of free space..."
            systemctl stop hydra-queue-runner
        fi
        if (( FREE_BYTES < EVAL_MIN_FREE_BYTES )); then
            echo "stopping Hydra evaluator due to lack of free space..."
            systemctl stop hydra-evaluator
        fi
      '';
      startAt = "*:0/5";
    };

    # Periodically compress build logs. The queue runner compresses
    # logs automatically after a step finishes, but this doesn't work
    # if the queue runner is stopped prematurely.
    systemd.services.hydra-compress-logs = {
      path = [pkgs.bzip2];
      # FIXME: use `find … -print0` and `xargs -0` here
      # FIXME: perhaps use GNU parallel instead of xargs
      script = ''
        find /var/lib/hydra/build-logs -type f -name "*.drv" -mtime +3 -size +0c \
            | xargs -r bzip2 -v -f
      '';
      startAt = "Sun 01:45";
    };

    services.postgresql.enable = mkIf haveLocalDB true;

    services.postgresql.identMap = optionalString haveLocalDB ''
      hydra-users hydra hydra
      hydra-users hydra-queue-runner hydra
      hydra-users hydra-www hydra
      hydra-users root hydra
    '';

    services.postgresql.authentication = optionalString haveLocalDB ''
      local hydra all ident map=hydra-users
    '';
  };
}
