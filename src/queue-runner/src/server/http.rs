use std::{net::SocketAddr, sync::Arc};

use crate::state::State;
use bytes::Bytes;
use http_body_util::{BodyExt as _, Full, combinators::BoxBody};
use tracing::Instrument as _;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("uuid error: `{0}`")]
    Uuid(#[from] uuid::Error),

    #[error("serde json error: `{0}`")]
    SerdeJson(#[from] serde_json::Error),

    #[error("hyper http error: `{0}`")]
    HyperHttp(#[from] hyper::http::Error),

    #[error("hyper error: `{0}`")]
    Hyper(#[from] hyper::Error),

    #[error("std io error: `{0}`")]
    Io(#[from] std::io::Error),

    #[error("anyhow error: `{0}`")]
    Anyhow(#[from] anyhow::Error),

    #[error("db error: `{0}`")]
    Sqlx(#[from] db::Error),

    #[error("Not found")]
    NotFound,

    #[error("Fatal")]
    Fatal,
}

impl Error {
    #[must_use]
    pub const fn get_status(&self) -> hyper::StatusCode {
        match *self {
            Self::Uuid(_)
            | Self::SerdeJson(_)
            | Self::HyperHttp(_)
            | Self::Hyper(_)
            | Self::Io(_)
            | Self::Anyhow(_)
            | Self::Sqlx(_)
            | Self::Fatal => hyper::StatusCode::INTERNAL_SERVER_ERROR,
            Self::NotFound => hyper::StatusCode::NOT_FOUND,
        }
    }

    #[must_use]
    pub fn get_body(&self) -> crate::io::Error {
        crate::io::Error {
            error: self.to_string(),
        }
    }
}

fn full<T: Into<Bytes>>(chunk: T) -> BoxBody<Bytes, hyper::Error> {
    Full::new(chunk.into())
        .map_err(|never| match never {})
        .boxed()
}

fn construct_json_response<U: serde::Serialize>(
    status: hyper::StatusCode,
    data: &U,
) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
    Ok(hyper::Response::builder()
        .status(status)
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .body(full(serde_json::to_string(data)?))?)
}

type Response = hyper::Response<BoxBody<Bytes, hyper::Error>>;

fn construct_json_ok_response<U: serde::Serialize>(data: &U) -> Result<Response, Error> {
    construct_json_response(hyper::StatusCode::OK, data)
}

pub struct Server {}
impl Server {
    pub async fn run(addr: SocketAddr, state: Arc<State>) -> Result<(), Error> {
        async move {
            let listener = tokio::net::TcpListener::bind(&addr).await?;
            let server_span = tracing::span!(tracing::Level::TRACE, "http_server", %addr);

            loop {
                let (stream, _) = listener.accept().await?;
                let io = hyper_util::rt::TokioIo::new(stream);

                let state = state.clone();
                tokio::task::spawn({
                    let server_span = server_span.clone();
                    async move {
                        if let Err(err) = hyper::server::conn::http1::Builder::new()
                            .serve_connection(
                                io,
                                hyper::service::service_fn(move |req| router(req, state.clone())),
                            )
                            .instrument(server_span.clone())
                            .await
                        {
                            tracing::error!("Error serving connection: {err:?}");
                        }
                    }
                });
            }
        }
        .await
    }
}

async fn router(
    req: hyper::Request<hyper::body::Incoming>,
    state: Arc<State>,
) -> Result<Response, Error> {
    let span = tracing::span!(
        tracing::Level::INFO,
        "request",
        method = ?req.method(),
        uri = ?req.uri(),
        headers = ?req.headers()
    );
    async move {
        let r = match (req.method(), req.uri().path()) {
            (&hyper::Method::GET, "/status" | "/status/") => handler::status::get(state).await,
            (&hyper::Method::GET, "/status/machines" | "/status/machines/") => {
                handler::status::machines(state).await
            }
            (&hyper::Method::GET, "/status/jobsets" | "/status/jobsets/") => {
                handler::status::jobsets(state)
            }
            (&hyper::Method::GET, "/status/builds" | "/status/builds/") => {
                handler::status::builds(state)
            }
            (&hyper::Method::GET, "/status/steps" | "/status/steps/") => {
                handler::status::steps(state)
            }
            (&hyper::Method::GET, "/status/runnable" | "/status/runnable/") => {
                handler::status::runnable(state)
            }
            (&hyper::Method::GET, "/status/queues" | "/status/queues/") => {
                handler::status::queues(state).await
            }
            (&hyper::Method::GET, "/status/queues/jobs" | "/status/queues/jobs/") => {
                handler::status::queue_jobs(state).await
            }
            (&hyper::Method::GET, "/status/queues/scheduled" | "/status/queues/scheduled/") => {
                handler::status::queue_scheduled(state).await
            }
            (&hyper::Method::POST, "/dump_status" | "/dump_status/") => {
                handler::dump_status::post(state).await
            }
            (&hyper::Method::PUT, "/build" | "/build/") => handler::build::put(req, state).await,
            (&hyper::Method::GET, "/metrics" | "/metrics/") => handler::metrics::get(state).await,
            _ => Err(Error::NotFound),
        };
        if let Err(r) = r.as_ref() {
            construct_json_response(r.get_status(), &r.get_body())
        } else {
            r
        }
    }
    .instrument(span)
    .await
}

mod handler {
    pub mod status {
        use super::super::{Error, Response, construct_json_ok_response};
        use crate::{io, state::State};

        #[tracing::instrument(skip(state), err)]
        pub async fn get(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let queue_stats = io::QueueRunnerStats::new(state.clone()).await;
            let sort_fn = state.config.get_machine_sort_fn();
            let free_fn = state.config.get_machine_free_fn();
            let machines = state
                .machines
                .get_all_machines()
                .into_iter()
                .map(|m| {
                    (
                        m.hostname.clone(),
                        crate::io::Machine::from_state(&m, sort_fn, free_fn),
                    )
                })
                .collect();
            let jobsets = state.jobsets.clone_as_io();
            let remote_stores = {
                let stores = state.remote_stores.read();
                stores.clone()
            };
            construct_json_ok_response(&io::DumpResponse::new(
                queue_stats,
                machines,
                jobsets,
                &state.store,
                &remote_stores,
            ))
        }

        #[tracing::instrument(skip(state), err)]
        pub async fn machines(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let sort_fn = state.config.get_machine_sort_fn();
            let free_fn = state.config.get_machine_free_fn();
            let machines = state
                .machines
                .get_all_machines()
                .into_iter()
                .map(|m| {
                    (
                        m.hostname.clone(),
                        crate::io::Machine::from_state(&m, sort_fn, free_fn),
                    )
                })
                .collect();
            construct_json_ok_response(&io::MachinesResponse::new(machines))
        }

        #[tracing::instrument(skip(state), err)]
        pub fn jobsets(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let jobsets = state.jobsets.clone_as_io();
            construct_json_ok_response(&io::JobsetsResponse::new(jobsets))
        }

        #[tracing::instrument(skip(state), err)]
        pub fn builds(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let builds = state.builds.clone_as_io();
            construct_json_ok_response(&io::BuildsResponse::new(builds))
        }

        #[tracing::instrument(skip(state), err)]
        pub fn steps(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let steps = state.steps.clone_as_io();
            construct_json_ok_response(&io::StepsResponse::new(steps))
        }

        #[tracing::instrument(skip(state), err)]
        pub fn runnable(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let steps = state.steps.clone_runnable_as_io();
            construct_json_ok_response(&io::StepsResponse::new(steps))
        }

        #[tracing::instrument(skip(state), err)]
        pub async fn queues(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let queues = state
                .queues
                .clone_inner()
                .await
                .into_iter()
                .map(|(s, q)| {
                    (
                        s,
                        q.clone_inner()
                            .into_iter()
                            .filter_map(|v| v.upgrade().map(Into::into))
                            .collect(),
                    )
                })
                .collect();
            construct_json_ok_response(&io::QueueResponse::new(queues))
        }

        #[tracing::instrument(skip(state), err)]
        pub async fn queue_jobs(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let stepinfos = state
                .queues
                .get_jobs()
                .await
                .into_iter()
                .map(Into::into)
                .collect();
            construct_json_ok_response(&io::StepInfoResponse::new(stepinfos))
        }

        #[tracing::instrument(skip(state), err)]
        pub async fn queue_scheduled(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let stepinfos = state
                .queues
                .get_scheduled()
                .await
                .into_iter()
                .map(Into::into)
                .collect();
            construct_json_ok_response(&io::StepInfoResponse::new(stepinfos))
        }
    }

    pub mod dump_status {
        use super::super::{Error, Response, construct_json_ok_response};
        use crate::{io, state::State};

        #[tracing::instrument(skip(state), err)]
        pub async fn post(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let mut db = state.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            tx.notify_dump_status().await?;
            tx.commit().await?;
            construct_json_ok_response(&io::Empty {})
        }
    }

    pub mod build {
        use bytes::Buf as _;
        use http_body_util::BodyExt as _;

        use super::super::{Error, Response, construct_json_ok_response};
        use crate::{io, state::State};

        #[tracing::instrument(skip(req, state), err)]
        pub async fn put(
            req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<Response, Error> {
            let whole_body = req.collect().await?.aggregate();
            let data: io::BuildPayload = serde_json::from_reader(whole_body.reader())?;

            state
                .queue_one_build(data.jobset_id, &nix_utils::StorePath::new(&data.drv))
                .await?;
            construct_json_ok_response(&io::Empty {})
        }
    }

    pub mod metrics {
        use super::super::{Error, Response, full};
        use crate::state::State;

        #[tracing::instrument(skip(state), err)]
        pub async fn get(state: std::sync::Arc<State>) -> Result<Response, Error> {
            let metrics = state.metrics.gather_metrics(&state).await?;
            Ok(hyper::Response::builder()
                .status(hyper::StatusCode::OK)
                .header(
                    hyper::header::CONTENT_TYPE,
                    "text/plain; version=0.0.4; charset=utf-8",
                )
                .body(full(metrics))?)
        }
    }
}
