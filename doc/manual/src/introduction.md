Introduction
============

About Hydra
-----------

Hydra is a tool for continuous integration testing and software release
that uses a purely functional language to describe build jobs and their
dependencies. Continuous integration is a simple technique to improve
the quality of the software development process. An automated system
continuously or periodically checks out the source code of a project,
builds it, runs tests, and produces reports for the developers. Thus,
various errors that might accidentally be committed into the code base
are automatically caught. Such a system allows more in-depth testing
than what developers could feasibly do manually:

-   Portability testing
    : The software may need to be built and tested on many different
    platforms. It is infeasible for each developer to do this before
    every commit.
-   Likewise, many projects have very large test sets (e.g., regression
    tests in a compiler, or stress tests in a DBMS) that can take hours
    or days to run to completion.
-   Many kinds of static and dynamic analyses can be performed as part
    of the tests, such as code coverage runs and static analyses.
-   It may also be necessary to build many different
    variants
    of the software. For instance, it may be necessary to verify that
    the component builds with various versions of a compiler.
-   Developers typically use incremental building to test their changes
    (since a full build may take too long), but this is unreliable with
    many build management tools (such as Make), i.e., the result of the
    incremental build might differ from a full build.
-   It ensures that the software can be built from the sources under
    revision control. Users of version management systems such as CVS
    and Subversion often forget to place source files under revision
    control.
-   The machines on which the continuous integration system runs ideally
    provides a clean, well-defined build environment. If this
    environment is administered through proper SCM techniques, then
    builds produced by the system can be reproduced. In contrast,
    developer work environments are typically not under any kind of SCM
    control.
-   In large projects, developers often work on a particular component
    of the project, and do not build and test the composition of those
    components (again since this is likely to take too long). To prevent
    the phenomenon of \`\`big bang integration\'\', where components are
    only tested together near the end of the development process, it is
    important to test components together as soon as possible (hence
    continuous integration
    ).
-   It allows software to be
    released
    by automatically creating packages that users can download and
    install. To do this manually represents an often prohibitive amount
    of work, as one may want to produce releases for many different
    platforms: e.g., installers for Windows and Mac OS X, RPM or Debian
    packages for certain Linux distributions, and so on.

In its simplest form, a continuous integration tool sits in a loop
building and releasing software components from a version management
system. For each component, it performs the following tasks:

-   It obtains the latest version of the component\'s source code from
    the version management system.
-   It runs the component\'s build process (which presumably includes
    the execution of the component\'s test set).
-   It presents the results of the build (such as error logs and
    releases) to the developers, e.g., by producing a web page.

Examples of continuous integration tools include Jenkins, CruiseControl
Tinderbox, Sisyphus, Anthill and BuildBot. These tools have various
limitations.

-   They do not manage the
    build environment
    . The build environment consists of the dependencies necessary to
    perform a build action, e.g., compilers, libraries, etc. Setting up
    the environment is typically done manually, and without proper SCM
    control (so it may be hard to reproduce a build at a later time).
    Manual management of the environment scales poorly in the number of
    configurations that must be supported. For instance, suppose that we
    want to build a component that requires a certain compiler X. We
    then have to go to each machine and install X. If we later need a
    newer version of X, the process must be repeated all over again. An
    ever worse problem occurs if there are conflicting, mutually
    exclusive versions of the dependencies. Thus, simply installing the
    latest version is not an option. Of course, we can install these
    components in different directories and manually pass the
    appropriate paths to the build processes of the various components.
    But this is a rather tiresome and error-prone process.
-   They do not easily support
    variability in software systems
    . A system may have a great deal of build-time variability: optional
    functionality, whether to build a debug or production version,
    different versions of dependencies, and so on. (For instance, the
    Linux kernel now has over 2,600 build-time configuration switches.)
    It is therefore important that a continuous integration tool can
    easily select and test different instances from the configuration
    space of the system to reveal problems, such as erroneous
    interactions between features. In a continuous integration setting,
    it is also useful to test different combinations of versions of
    subsystems, e.g., the head revision of a component against stable
    releases of its dependencies, and vice versa, as this can reveal
    various integration problems.

*Hydra*, is a continuous integration tool that solves these problems. It
is built on top of the [Nix package manager](http://nixos.org/nix/),
which has a purely functional language for describing package build
actions and their dependencies. This allows the build environment for
projects to be produced automatically and deterministically, and
variability in components to be expressed naturally using functions; and
as such is an ideal fit for a continuous build system.

About Us
--------

Hydra is the successor of the Nix Buildfarm, which was developed in
tandem with the Nix software deployment system. Nix was originally
developed at the Department of Information and Computing Sciences,
Utrecht University by the TraCE project (2003-2008). The project was
funded by the Software Engineering Research Program Jacquard to improve
the support for variability in software systems. Funding for the
development of Nix and Hydra is now provided by the NIRICT LaQuSo Build
Farm project.

About this Manual
-----------------

This manual tells you how to install the Hydra buildfarm software on
your own server and how to operate that server using its web interface.

License
-------

Hydra is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your
option) any later version.

Hydra is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the [GNU General Public
License](http://www.gnu.org/licenses/) for more details.

Hydra at `nixos.org`
--------------------

The `nixos.org` installation of Hydra runs at
[`http://hydra.nixos.org/`](http://hydra.nixos.org/). That installation
is used to build software components from the [Nix](http://nixos.org),
[NixOS](http://nixos.org/nixos), [GNU](http://www.gnu.org/),
[Stratego/XT](http://strategoxt.org), and related projects.

If you are one of the developers on those projects, it is likely that
you will be using the NixOS Hydra server in some way. If you need to
administer automatic builds for your project, you should pull the right
strings to get an account on the server. This manual will tell you how
to set up new projects and build jobs within those projects and write a
release.nix file to describe the build process of your project to Hydra.
You can skip the next chapter.

If your project does not yet have automatic builds within the NixOS
Hydra server, it may actually be eligible. We are in the process of
setting up a large buildfarm that should be able to support open source
and academic software projects. Get in touch.

Hydra on your own buildfarm
---------------------------

If you need to run your own Hydra installation,
[installation chapter](installation.md) explains how to download and install the
system on your own server.
