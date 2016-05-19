Hydra also supports declarative projects, where jobsets are generated and configured automatically from specification files instead of being managed through the UI. A jobset specification is a JSON object containing the configuration of the jobset, for example:

```JSON
{
    "enabled": 1,
    "hidden": false,
    "description": "js",
    "nixexprinput": "src",
    "nixexprpath": "release.nix",
    "checkinterval": 300,
    "schedulingshares": 100,
    "enableemail": false,
    "emailoverride": "",
    "keepnr": 3,
    "inputs": {
        "src": { "type": "git", "value": "git://github.com/shlevy/declarative-hydra-example.git", "emailresponsible": false },
        "nixpkgs": { "type": "git", "value": "git://github.com/NixOS/nixpkgs.git release-16.03", "emailresponsible": false }
    }
}
```

To configure a declarative project, take the following steps:

1. Create a jobset repository in the normal way (e.g. a git repo with a `release.nix` file, any other needed helper files, and taking any kind of hydra input), but without adding it to the UI. The nix expression of this repository should contain a single job, named `jobsets`. The output of the `jobsets` job should be a JSON file containing an object of jobset specifications. Each member of the object will become a jobset of the project, configured by the corresponding jobset specification.
2. In some hydra-fetchable source (potentially, but not necessarily, the same repo you created in step 1), create a JSON file containing a jobset specification that points to the jobset repository you created in the first step, specifying any needed inputs (e.g. nixpkgs) as necessary.
3. In the project creation/edit page, set declarative input type, declarative input value, and declarative spec file to point to the source and JSON file you created in step 2.

Hydra will create a special jobset named `.jobsets`, which whenever evaluated will go through the steps above in reverse order:

1. Hydra will fetch the input specified by the declarative input type and value.
2. Hydra will use the configuration given in the declarative spec file as the jobset configuration for this evaluation. In addition to any inputs specified in the spec file, hydra will also pass the `declInput` argument corresponding to the input fetched in step 1.
3. As normal, hydra will build the jobs specified in the jobset repository, which in this case is the single `jobsets` job. When that job completes, hydra will read the created jobset specifications and create corresponding jobsets in the project, disabling any jobsets that used to exist but are not present in the current spec.
