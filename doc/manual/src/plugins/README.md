# Plugins

This chapter describes all plugins present in Hydra.

### Inputs

Hydra supports the following inputs:

- Bazaar input
- Darcs input
- Git input
- Mercurial input
- Path input

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

Compresses build logs after a build with bzip2.

### Configuration options

- `compress_build_logs`

Enable log compression

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

## Email notification

Sends email notification if build status changes.

### Configuration options

- `email_notification`

## Gitea status

Sets Gitea CI status

### Configuration options

- `gitea_authorization.<repo-owner>`

## GitHub pulls

Create jobs based on open GitHub pull requests

### Configuration options

- `github_authorization.<repo-owner>`

## Github refs

Hydra plugin for retrieving the list of references (branches or tags) from
GitHub following a certain naming scheme.

### Configuration options

- `github_endpoint`
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
```

## GitLab pulls

Create jobs based on open gitlab pull requests.

### Configuration options

- `gitlab_authorization.<projectId>`

## Gitlab status

Sets Gitlab CI status.

### Configuration options

- `gitlab_authorization.<projectId>`

## HipChat notification

Sends hipchat chat notifications when a build finish.

### Configuration options

- `hipchat.[].jobs`
- `hipchat.[].builds`
- `hipchat.[].token`
- `hipchat.[].notify`

## InfluxDB notification

Writes InfluxDB events when a builds finished.

### Configuration options

- `influxdb.url`
- `influxdb.db`

## Run command

Runs a shell command when the build is finished.

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
