Using the external API
======================

To be able to create integrations with other services, Hydra exposes an
external API that you can manage projects with.

The API is accessed over HTTP(s) where all data is sent and received as
JSON.

Creating resources requires the caller to be authenticated, while
retrieving resources does not.

The API does not have a separate URL structure for it\'s endpoints.
Instead you request the pages of the web interface as `application/json`
to use the API.

List projects
-------------

To list all the `projects` of the Hydra install:

    GET /
    Accept: application/json

This will give you a list of `projects`, where each `project` contains
general information and a list of its `job sets`.

**Example**

    curl -i -H 'Accept: application/json' \
        https://hydra.nixos.org

**Note:** this response is truncated

    GET https://hydra.nixos.org/
    HTTP/1.1 200 OK
    Content-Type: application/json

    [
      {
        "displayname": "Acoda",
        "name": "acoda",
        "description": "Acoda is a tool set for automatic data migration along an evolving data model",
        "enabled": 0,
        "owner": "sander",
        "hidden": 1,
        "jobsets": [
          "trunk"
        ]
      },
      {
        "displayname": "cabal2nix",
        "name": "cabal2nix",
        "description": "Convert Cabal files into Nix build instructions",
        "enabled": 0,
        "owner": "simons@cryp.to",
        "hidden": 1,
        "jobsets": [
          "master"
        ]
      }
    ]

Get a single project
--------------------

To get a single `project` by identifier:

    GET /project/:project-identifier
    Accept: application/json

**Example**

    curl -i -H 'Accept: application/json' \
        https://hydra.nixos.org/project/hydra

    GET https://hydra.nixos.org/project/hydra
    HTTP/1.1 200 OK
    Content-Type: application/json

    {
      "description": "Hydra, the Nix-based continuous build system",
      "hidden": 0,
      "displayname": "Hydra",
      "jobsets": [
        "hydra-master",
        "hydra-ant-logger-trunk",
        "master",
        "build-ng"
      ],
      "name": "hydra",
      "enabled": 1,
      "owner": "eelco"
    }

Get a single job set
--------------------

To get a single `job set` by identifier:

    GET /jobset/:project-identifier/:jobset-identifier
    Content-Type: application/json

**Example**

    curl -i -H 'Accept: application/json' \
        https://hydra.nixos.org/jobset/hydra/build-ng

    GET https://hydra.nixos.org/jobset/hydra/build-ng
    HTTP/1.1 200 OK
    Content-Type: application/json

    {
      "errormsg": "evaluation failed due to signal 9 (Killed)",
      "fetcherrormsg": null,
      "nixexprpath": "release.nix",
      "nixexprinput": "hydraSrc",
      "emailoverride": "rob.vermaas@gmail.com, eelco.dolstra@logicblox.com",
      "jobsetinputs": {
        "officialRelease": "false",
        "hydraSrc": "https://github.com/NixOS/hydra.git build-ng",
        "nixpkgs": "https://github.com/NixOS/nixpkgs.git release-14.12"
      },
      "enabled": 0
    }

List evaluations
----------------

To list the `evaluations` of a `job set` by identifier:

    GET /jobset/:project-identifier/:jobset-identifier/evals
    Content-Type: application/json

**Example**

    curl -i -H 'Accept: application/json' \
        https://hydra.nixos.org/jobset/hydra/build-ng/evals

**Note:** this response is truncated

    GET https://hydra.nixos.org/jobset/hydra/build-ng/evals
    HTTP/1.1 200 OK
    Content-Type: application/json

    {
      "evals": [
        {
          "jobsetevalinputs": {
            "nixpkgs": {
              "dependency": null,
              "type": "git",
              "value": null,
              "uri": "https://github.com/NixOS/nixpkgs.git",
              "revision": "f60e48ce81b6f428d072d3c148f6f2e59f1dfd7a"
            },
            "hydraSrc": {
              "dependency": null,
              "type": "git",
              "value": null,
              "uri": "https://github.com/NixOS/hydra.git",
              "revision": "48d6f0de2ab94f728d287b9c9670c4d237e7c0f6"
            },
            "officialRelease": {
              "dependency": null,
              "value": "false",
              "type": "boolean",
              "uri": null,
              "revision": null
            }
          },
          "hasnewbuilds": 1,
          "builds": [
            24670686,
            24670684,
            24670685,
            24670687
          ],
          "id": 1213758
        }
      ],
      "first": "?page=1",
      "last": "?page=1"
    }

Get a single build
------------------

To get a single `build` by its id:

    GET /build/:build-id
    Content-Type: application/json

**Example**

    curl -i -H 'Accept: application/json' \
        https://hydra.nixos.org/build/24670686

    GET /build/24670686
    HTTP/1.1 200 OK
    Content-Type: application/json

    {
      "job": "tests.api.x86_64-linux",
      "jobsetevals": [
        1213758
      ],
      "buildstatus": 0,
      "buildmetrics": null,
      "project": "hydra",
      "system": "x86_64-linux",
      "priority": 100,
      "releasename": null,
      "starttime": 1439402853,
      "nixname": "vm-test-run-unnamed",
      "timestamp": 1439388618,
      "id": 24670686,
      "stoptime": 1439403403,
      "jobset": "build-ng",
      "buildoutputs": {
        "out": {
          "path": "/nix/store/lzrxkjc35mhp8w7r8h82g0ljyizfchma-vm-test-run-unnamed"
        }
      },
      "buildproducts": {
        "1": {
          "path": "/nix/store/lzrxkjc35mhp8w7r8h82g0ljyizfchma-vm-test-run-unnamed",
          "defaultpath": "log.html",
          "type": "report",
          "sha256hash": null,
          "filesize": null,
          "name": "",
          "subtype": "testlog"
        }
      },
      "finished": 1
    }
