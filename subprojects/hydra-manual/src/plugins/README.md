# Plugins

This chapter describes all plugins present in Hydra.

### Inputs

Hydra supports the following inputs:

- Bazaar input
- Darcs input
- Git input
- Mercurial input
- Path input

Input plugins run in three places:

- `hydra-fetch-input`, run by the evaluator, calls `fetchInput`.
- `hydra-notify` calls `getCommits`, to find the authors to blame for a failure.
- `hydra-server` calls `supportedInputTypes`, to list the input types a jobset may use.
  That must not run any commands: it should only report the types the plugin handles.

### Running programs

Hydra's processes have no `PATH`.
Each program Hydra itself runs is named by its own environment variable, `HYDRA_PROGRAM_<NAME>`: the program's name upper-cased, with `-` as `_`, such as `HYDRA_PROGRAM_GIT`.
Hydra's packaging sets these for each program, and a missing one is an error rather than whatever a `PATH` lookup would find.
In Perl, `program("git")` from `Hydra::Helper::Exec` gives the location.

Hydra can't know what a plugin from outside Hydra, or a command `RunCommand` runs, will need.
Those get the plugin extension path instead, `HYDRA_PLUGIN_PATH`, which the NixOS option `services.hydra-dev.pluginPath` sets.
`RunCommand` puts it on its commands' `PATH`.
A plugin can do the same around a command it runs, with `local $ENV{PATH} = pluginPath();`, also from `Hydra::Helper::Exec`.

## Bitbucket pull requests

Create jobs based on open bitbucket pull requests.

### Configuration options

- `bitbucket_authorization.<owner>`

## Bitbucket status

Sets Bitbucket CI status.

### Configuration options

- `enable_bitbucket_status`
- `bitbucket.username`
- `bitbucket.password`

## CircleCI Notification

Sets CircleCI status.

### Configuration options

- `circleci.[].jobs`
- `circleci.[].vcstype`
- `circleci.[].token`

## Compress build logs

Compresses build logs after a build with bzip2 or zstd.

### Configuration options

- `compress_build_logs`

Enable log compression

- `compress_build_logs_compression`

Which compression format to use. Valid values are bzip2 (default) and zstd.

- `compress_build_logs_silent`

Whether to compress logs silently.

### Example

```xml
compress_build_logs = 1
```

## Coverity Scan

Uploads source code to [coverity scan](https://scan.coverity.com).

### Configuration options

- `coverityscan.[].jobs`
- `coverityscan.[].project`
- `coverityscan.[].email`
- `coverityscan.[].token`
- `coverityscan.[].scanurl`

## Email notification, builds

Sends email notification if build status changes.

_This plugin is named just `EmailNotification` for historical reasons, and it
should be renamed to `EmailNotificationBuild`._

### Configuration options

- `email_notifications.build` --- mail about finished builds, to whoever
  maintains the job
- `email_notification` --- deprecated; enables this and
  `email_notifications.eval` below. Setting it as well as the block is an error.

### Example

```xml
<email_notifications>
  build = 1
</email_notifications>
```

## Email notification, evaluation errors

Tells a project's owner when one of its jobsets fails to evaluate, or evaluates
with jobs that did not.

The owner must also have "Receive evaluation error notifications" set on their
user page; unlike build notification, it is off by default. Only a changed
error is reported, so a jobset failing the same way is not mailed about
repeatedly.

### Configuration options

- `email_notifications.eval`
- `email_notification` --- deprecated; enables this and
  `email_notifications.build` above. Setting it as well as the block is an error.

### Example

```xml
<email_notifications>
  eval = 1
</email_notifications>
```

## Gitea status

Sets Gitea CI status

### Configuration options

- `gitea_authorization.<repo-owner>`

## GitHub pulls

Create jobs based on open GitHub pull requests. The input's value is
`OWNER REPO [HOST]`, where `HOST` selects a GitHub Enterprise server.

### Configuration options

- `github_authorization.<repo-owner>`
- `githubpulls.allowed_repos`: if set, only these repositories can be fetched.
  Entries are `owner/repo` or `owner/*`, space-separated or with the key
  repeated. Matching is exact, including case.
- `githubpulls.allowed_hosts`: the GitHub Enterprise hosts that can be fetched
  from. Required if hosts are manually specified, and can also be used to block
  or allow github.com if provided. The default behavior is to allow github.com,
  and block any other host that is manually specified.

### Example

```xml
<githubpulls>
  allowed_hosts = github.com git.example.com
  allowed_repos = publicorg/* privateorg/myproject
</githubpulls>
```

## Github refs

Hydra plugin for retrieving the list of references (branches or tags) from
GitHub following a certain naming scheme.

### Configuration options

- `github_endpoint` (defaults to https://api.github.com)
- `github_authorization.<repo-owner>`

## Github status

Sets GitHub CI status.

### Configuration options

- `githubstatus.[].jobs`

Regular expression for jobs to match in the format `project:jobset:job`.
This field is required and has no default value.

- `githubstatus.[].excludeBuildFromContext`

Don't include the build's ID in the status.

- `githubstatus.[].context`

Context shown in the status

- `githubstatus.[].useShortContext`

Renames `continuous-integration/hydra` to `ci/hydra` and removes the PR suffix
from the name. Useful to see the full path in GitHub for long job names.

- `githubstatus.[].description`

Description shown in the status. Defaults to `Hydra build #<build-id> of
<jobname>`

- `githubstatus.[].inputs`

The input which corresponds to the github repo/rev whose
status we want to report. Can be repeated.

- `githubstatus.[].authorization`

Verbatim contents of the Authorization header. See
[GitHub documentation](https://developer.github.com/v3/#authentication) for
details. This field is only used if `github_authorization.<repo-owner>` is not set.

- `githubstatus.[].host`

The GitHub host to send statuses to, such as a GitHub Enterprise server's
`git.example.com`. Defaults to `github.com`. Statuses are only sent for flakes
and inputs on this host: the `?host=` of a `github:` flake (github.com if it
has none), the host of a `git+https://` or `git+ssh://` flake, or the host of
a non-flake input's git URL.

To send statuses to more than one host, add a `<githubstatus>` block for each.
Note that matching is exact, including case.

### Example

```xml
<githubstatus>
  jobs = test:pr:build
  ## This example will match all jobs
  #jobs = .*
  inputs = src
  authorization = Bearer gha-secret😱secret😱secret😱
  excludeBuildFromContext = 1
</githubstatus>

## Statuses for the same jobs on a GitHub Enterprise server
<githubstatus>
  jobs = test:pr:build
  inputs = src
  host = git.example.com
  authorization = Bearer ghe-secret😱secret😱secret😱
  excludeBuildFromContext = 1
</githubstatus>
```

## GitLab pulls

Create jobs based on open gitlab pull requests.

### Configuration options

- `gitlab_authorization.<projectId>`

## Gitlab status

Sets Gitlab CI status.

### Configuration options

- `gitlab_authorization.<projectId>`

## InfluxDB notification

Writes InfluxDB events when a builds finished.

### Configuration options

- `influxdb.url`
- `influxdb.db`

## RunCommand

Runs a shell command when the build is finished.

See [The RunCommand Plugin](./RunCommand.md) for more information.

### Configuration options:

- `runcommand.[].job`

Regular expression for jobs to match in the format `project:jobset:job`.
Defaults to `*:*:*`.

- `runcommand.[].command`

Command to run. Can use the `$HYDRA_JSON` environment variable to access
information about the build.

### Example

```xml
<runcommand>
  job = myProject:*:*
  command = cat $HYDRA_JSON > /tmp/hydra-output
</runcommand>
```

## S3 backup

Upload nars and narinfos to S3 storage.

### Configuration options

- `s3backup.[].jobs`
- `s3backup.[].compression_type`
- `s3backup.[].name`
- `s3backup.[].prefix`

## Slack notification

Sending Slack notifications about build results.

### Configuration options

- `slack.[].jobs`
- `slack.[].force`
- `slack.[].url`


## SoTest

Scheduling hardware tests to SoTest controller

This plugin submits tests to a SoTest controller for all builds that contain
two products matching the subtypes "sotest-binaries" and "sotest-config".

Build products are declared by the file "nix-support/hydra-build-products"
relative to the root of a build, in the following format:

```
 file sotest-binaries /nix/store/…/binaries.zip
 file sotest-config /nix/store/…/config.yaml
```

### Configuration options

- `sotest.[].uri`

URL of the controller, defaults to `https://opensource.sotest.io`

- `sotest.[].authfile`

File containing `username:password`

- `sotest.[].priority`

Optional priority setting.

### Example

```xml
 <sotest>
   uri = https://sotest.example
   authfile = /var/lib/hydra/sotest.auth
   priority = 1
 </sotest>
 ```
