insert into projects(name, displayName, description) values('patchelf', 'PatchELF', 'A tool for modifying ELF binaries');
insert into jobSets(project, name, description, nixExprInput, nixExprPath) values('patchelf', 'trunk', 'PatchELF trunk', 'patchelfSrc', 'release.nix');
insert into jobSetInputs(project, jobset, name, type) values('patchelf', 'trunk', 'patchelfSrc', 'path');
insert into jobSetInputAlts(project, jobset, input, altnr, value) values('patchelf', 'trunk', 'patchelfSrc', 0, '/home/eelco/Dev/patchelf-wc');
insert into jobSetInputs(project, jobset, name, type) values('patchelf', 'trunk', 'nixpkgs', 'path');
insert into jobSetInputAlts(project, jobset, input, altnr, value) values('patchelf', 'trunk', 'nixpkgs', 0, '/home/eelco/Dev/nixpkgs-wc');
insert into jobSetInputs(project, jobset, name, type) values('patchelf', 'trunk', 'release', 'path');
insert into jobSetInputAlts(project, jobset, input, altnr, value) values('patchelf', 'trunk', 'release', 0, '/home/eelco/Dev/release');
insert into jobSetInputs(project, jobset, name, type) values('patchelf', 'trunk', 'system', 'string');
insert into jobSetInputAlts(project, jobset, input, altnr, value) values('patchelf', 'trunk', 'system', 0, 'i686-linux');
insert into jobSetInputAlts(project, jobset, input, altnr, value) values('patchelf', 'trunk', 'system', 1, 'x86_64-linux');

insert into projects(name, displayName, description) values('nix', 'Nix', 'The Nix package manager');

insert into projects(name, displayName, description) values('nixpkgs', 'Nixpkgs', 'The Nix Packages collection');

--insert into projects(name) values('nixpkgs');
--insert into jobSets(project, name) values('nixpkgs', 'trunk');
--insert into jobSets(project, name) values('nixpkgs', 'stdenv-branch');
