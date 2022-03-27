{ exposeUnderlyingJob, exposeDependentJob }:
with import ../config.nix;
let
  underlyingJob = mkDerivation {
    name = "underlying-job";
    builder = ../empty-dir-builder.sh;
  };

  dependentJob = mkDerivation {
    name = "dependent-job";
    builder = ../empty-dir-builder.sh;
    inherit underlyingJob;
  };
in
(if exposeUnderlyingJob then { inherit underlyingJob; } else { }) //
(if exposeDependentJob then { inherit dependentJob; } else { }) //
{ }
