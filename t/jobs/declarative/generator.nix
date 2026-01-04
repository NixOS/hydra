{ jobspath, ... }:
with import ../config.nix;
{
  jobsets = mkDerivation {
    name = "jobsets";
    builder = ./generator.sh;
    jobsets = builtins.toJSON {
      my-jobset = {
        enabled = 1;
        hidden = false;
        description = "my-declarative-jobset";
        nixexprinput = "src";
        nixexprpath = "one-job.nix";
        checkinterval = 300;
        schedulingshares = 100;
        enableemail = false;
        emailoverride = "";
        keepnr = 3;
        inputs = {
          src = {
            type = "path";
            value = jobspath;
            emailresponsible = false;
          };
        };
      };
    };
  };
}
