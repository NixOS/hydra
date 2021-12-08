## The RunCommand Plugin

Hydra supports executing a program after certain builds finish.
This behavior is disabled by default.

Hydra executes these commands under the `hydra-notify` service.

### Static Commands

Configure specific commands to execute after the specified matching job finishes.

#### Configuration

- `runcommand.[].job`

A matcher for jobs to match in the format `project:jobset:job`. Defaults to `*:*:*`.

**Note:** This matcher format is not a regular expression.
The `*` is a wildcard for that entire section, partial matches are not supported.

- `runcommand.[].command`

Command to run. Can use the `$HYDRA_JSON` environment variable to access information about the build.

### Example

```xml
<runcommand>
  job = myProject:*:*
  command = cat $HYDRA_JSON > /tmp/hydra-output
</runcommand>
```

### Dynamic Commands

Hydra can optionally run RunCommand hooks defined dynamically by the jobset.
This must be turned on explicitly in the `hydra.conf` and per jobset.

#### Behavior

Hydra will execute any program defined under the `runCommandHook` attribute set. These jobs must have a single output named `out`, and that output must be an executable file located directly at `$out`.

#### Security Properties

Safely deploying dynamic commands requires careful design of your Hydra jobs. Allowing arbitrary users to define attributes in your top level attribute set will allow that user to execute code on your Hydra.

If a jobset has dynamic commands enabled, you must ensure only trusted users can define top level attributes.


#### Configuration

- `dynamicruncommand.enable`

Set to 1 to enable dynamic RunCommand program execution.

#### Example

In your Hydra configuration, specify:

```xml
<dynamicruncommand>
  enable = 1
</dynamicruncommand>
```

Then create a job named `runCommandHook.example` in your jobset:

```
{ pkgs, ... }: {
    runCommandHook = {
        recurseForDerivations = true;

        example = pkgs.writeScript "run-me" ''
          #!${pkgs.runtimeShell}

          ${pkgs.jq}/bin/jq . "$HYDRA_JSON"
        '';
    };
}
```

After the `runcommandHook.example` build finishes that script will execute.
