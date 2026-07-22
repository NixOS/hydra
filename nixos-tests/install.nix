{
  system,
  nixpkgs,
  common,
}:

(import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).simpleTest {
  name = "hydra-install";
  nodes.server = common.serverConfig;
  nodes.builder = common.builderConfig;
  testScript = ''
    server.wait_for_unit("hydra-init.service")
    server.succeed("systemctl status hydra-server.socket")
    server.wait_for_unit("hydra-server.service")
    server.wait_for_unit("hydra-evaluator.service")
    server.wait_for_unit("hydra-queue-runner-dev.service")
    builder.wait_for_unit("hydra-queue-builder-dev.service")
    server.wait_for_open_port(3000)
    server.succeed("curl --fail http://localhost:3000/")
  '';
}
