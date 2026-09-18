//! `AdHocService`: dispatches derivations `hydra-ad-hoc` received inline
//! over the daemon protocol, bypassing `Builds`/`Steps`/`Queues` entirely.
//! See [`crate::state::State::dispatch_inline_derivation`] for why: Nix's
//! trusted-client build-hook fast path never uploads a `.drv` file for
//! these, so there is nothing for the normal ingestion pipeline to read.
//!
//! Unlike [`super::grpc::RunnerService`], this service is called by
//! `hydra-ad-hoc`, not by builder machines, so it is not wrapped in
//! [`super::grpc::CheckAuthInterceptor`] and has no builder-facing auth story
//! of its own yet (see where it is added to the server in `grpc.rs`).

use std::sync::Arc;

use harmonia_store_derivation::derivation::BasicDerivation;
use harmonia_store_derivation::derived_path::OutputName;

use hydra_proto::ad_hoc_service_server::AdHocService;
use hydra_proto::{
    Dispatched, SubmitDerivationEvent, SubmitDerivationRequest, submit_derivation_event,
};

use crate::state::State;

type AdHocResult<T> = Result<tonic::Response<T>, tonic::Status>;
type SubmitDerivationResponseStream = std::pin::Pin<
    Box<dyn futures::Stream<Item = Result<SubmitDerivationEvent, tonic::Status>> + Send>,
>;

#[allow(missing_debug_implementations)]
#[derive(Clone)]
pub struct Server {
    state: Arc<State>,
}

impl Server {
    #[must_use]
    pub const fn new(state: Arc<State>) -> Self {
        Self { state }
    }
}

#[tonic::async_trait]
impl AdHocService for Server {
    type SubmitDerivationStream = SubmitDerivationResponseStream;

    #[tracing::instrument(skip(self, req), err)]
    async fn submit_derivation(
        &self,
        req: tonic::Request<SubmitDerivationRequest>,
    ) -> AdHocResult<Self::SubmitDerivationStream> {
        let req = req.into_inner();
        let drv: BasicDerivation = req
            .drv
            .ok_or_else(|| tonic::Status::invalid_argument("missing drv"))?
            .try_into()
            .map_err(|e| tonic::Status::invalid_argument(format!("invalid drv: {e}")))?;
        let drv_path = req
            .drv_path
            .ok_or_else(|| tonic::Status::invalid_argument("missing drv_path"))?
            .0;
        let wanted_outputs = req
            .wanted_outputs
            .into_iter()
            .map(|s| {
                s.parse::<OutputName>().map_err(|e| {
                    tonic::Status::invalid_argument(format!("invalid output name: {e}"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;

        let (internal_build_id, machine_hostname, rx) = self
            .state
            .dispatch_inline_derivation(drv, drv_path, wanted_outputs)
            .await
            .map_err(|e| tonic::Status::unavailable(format!("dispatch failed: {e}")))?;

        let (tx, out_rx) = tokio::sync::mpsc::channel(2);
        tokio::spawn(async move {
            if tx
                .send(Ok(SubmitDerivationEvent {
                    event: Some(submit_derivation_event::Event::Dispatched(Dispatched {
                        machine_hostname,
                    })),
                }))
                .await
                .is_err()
            {
                return;
            }

            let result = match rx.await {
                Ok(result) => build_result_to_event(&result),
                Err(_) => SubmitDerivationEvent {
                    event: Some(submit_derivation_event::Event::Result(
                        hydra_proto::SubmitDerivationResult {
                            success: false,
                            error_msg: format!(
                                "builder for {internal_build_id} disappeared before reporting a result"
                            ),
                            outputs: std::collections::HashMap::new(),
                        },
                    )),
                },
            };
            let _ = tx.send(Ok(result)).await;
        });

        Ok(tonic::Response::new(
            Box::pin(tokio_stream::wrappers::ReceiverStream::new(out_rx))
                as Self::SubmitDerivationStream,
        ))
    }
}

/// Translate the builder's `BuildResultInfo` into the event
/// `hydra-ad-hoc` gets over `SubmitDerivation`.
fn build_result_to_event(result: &hydra_proto::BuildResultInfo) -> SubmitDerivationEvent {
    let success = result.result_state() == hydra_proto::BuildResultState::Success;
    let mut outputs = std::collections::HashMap::with_capacity(result.output_infos.len());
    for (name, info) in &result.output_infos {
        let Some(path) = &info.path else { continue };
        outputs.insert(name.clone(), path.clone());
    }
    SubmitDerivationEvent {
        event: Some(submit_derivation_event::Event::Result(
            hydra_proto::SubmitDerivationResult {
                success,
                error_msg: result.error_msg.clone().unwrap_or_default(),
                outputs,
            },
        )),
    }
}
