//! gRPC client to `hydra-queue-runner`'s `AdHocService`, used by
//! [`crate::handler::HydraDaemonHandler::build_derivation`] for Nix's
//! trusted-client fast path (see the module docs on `handler.rs`).
//!
//! This client has no TLS configuration of its own. If the queue runner's
//! gRPC listener has mTLS enabled (`state.mtls.enabled()`, see
//! `hydra-queue-runner/src/server/grpc.rs`), that listener requires every
//! connection — this one included — to present a client certificate; a
//! plain `http://` connection will fail outright rather than merely being
//! treated as unauthenticated. `hydra-builder` already carries the
//! `ClientTlsConfig`/`Identity`/`Certificate` wiring this would need
//! (`hydra-builder/src/config.rs` and `grpc.rs:198-260`) — this client
//! needs the same treatment before `hydra-ad-hoc` can be deployed against
//! an mTLS-enabled queue runner. Tracked as a known gap, not yet fixed.

use hydra_proto::ad_hoc_service_client::AdHocServiceClient;

/// A lazy channel: connecting does not block on the queue runner being up
/// (or on this call), matching the "start even if the queue runner isn't
/// there yet" tolerance the rest of `hydra-ad-hoc` has for its Postgres
/// dependency.
pub(crate) fn connect(
    addr: &str,
) -> Result<AdHocServiceClient<tonic::transport::Channel>, tonic::transport::Error> {
    let endpoint = tonic::transport::Endpoint::from_shared(addr.to_owned())?;
    Ok(AdHocServiceClient::new(endpoint.connect_lazy()))
}
