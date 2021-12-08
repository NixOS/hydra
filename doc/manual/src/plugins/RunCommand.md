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
