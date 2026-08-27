# OpenTelemetry (OTLP) options, shared by every hydra service that links
# `hydra-tracing`. The wiring is identical for all of them — only the name in
# the docs differs — so it lives here rather than being copied per module.
{ lib }:

{
  # `component` names the service in option descriptions; `binary` is what the
  # collector sees when `serviceName` is left unset.
  mkOtelOption =
    { component, binary }:
    lib.mkOption {
      description = "OpenTelemetry (OTLP) tracing options.";
      default = { };
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption ''
            OpenTelemetry tracing. Builds ${component} with the `otel`
            cargo feature and exports spans via OTLP/gRPC, configured
            through the standard `OTEL_*` environment variables
          '';

          endpoint = lib.mkOption {
            description = "OTLP collector endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`). The exporter uses gRPC, so point at the gRPC port (typically 4317).";
            type = lib.types.nullOr lib.types.singleLineStr;
            default = null;
            example = "http://127.0.0.1:4317";
          };

          protocol = lib.mkOption {
            description = "OTLP protocol (`OTEL_EXPORTER_OTLP_PROTOCOL`).";
            type = lib.types.nullOr (
              lib.types.enum [
                "grpc"
                "http/protobuf"
                "http/json"
              ]
            );
            default = null;
          };

          headers = lib.mkOption {
            description = "Headers sent to the collector (`OTEL_EXPORTER_OTLP_HEADERS`). Ends up in the world-readable systemd unit, so do not put secrets here.";
            type = lib.types.nullOr lib.types.singleLineStr;
            default = null;
            example = "authorization=Bearer token";
          };

          serviceName = lib.mkOption {
            description = "Service name reported to the collector (`OTEL_SERVICE_NAME`). Defaults to the binary name (`${binary}`).";
            type = lib.types.nullOr lib.types.singleLineStr;
            default = null;
          };

          extraEnv = lib.mkOption {
            description = "Additional `OTEL_*` environment variables not exposed as dedicated options.";
            type = lib.types.attrsOf lib.types.singleLineStr;
            default = { };
            example = {
              OTEL_TRACES_SAMPLER = "parentbased_traceidratio";
              OTEL_TRACES_SAMPLER_ARG = "0.1";
            };
          };
        };
      };
    };

  # The `OTEL_*` environment for a service unit. Empty when tracing is off, so
  # it can be merged unconditionally.
  otelEnv =
    otel:
    lib.optionalAttrs otel.enable (
      lib.filterAttrs (_: v: v != null) {
        OTEL_EXPORTER_OTLP_ENDPOINT = otel.endpoint;
        OTEL_EXPORTER_OTLP_PROTOCOL = otel.protocol;
        OTEL_EXPORTER_OTLP_HEADERS = otel.headers;
        OTEL_SERVICE_NAME = otel.serviceName;
      }
      // otel.extraEnv
    );
}
