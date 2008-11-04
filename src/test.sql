insert into projects(name) values('patchelf');
insert into jobSets(project, name, description, nixExprInput, nixExprPath) values('patchelf', 'trunk', 'PatchELF', 'patchelfSrc', 'release.nix');
insert into jobSetInputs(project, job, name, type, uri) values('patchelf', 'trunk', 'patchelfSrc', 'path', '/home/eelco/Dev/patchelf-wc');
insert into jobSetInputs(project, job, name, type, uri) values('patchelf', 'trunk', 'nixpkgs', 'path', '/home/eelco/Dev/nixpkgs-wc');
insert into jobSetInputs(project, job, name, type, uri) values('patchelf', 'trunk', 'release', 'path', '/home/eelco/Dev/release');

--insert into projects(name) values('nixpkgs');
--insert into jobSets(project, name) values('nixpkgs', 'trunk');
--insert into jobSets(project, name) values('nixpkgs', 'stdenv-branch');
