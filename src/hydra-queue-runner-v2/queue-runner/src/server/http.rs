use std::{net::SocketAddr, sync::Arc};

use crate::state::State;
use bytes::Bytes;
use http_body_util::{BodyExt, Full, combinators::BoxBody};
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
    #[allow(dead_code)]
    Fatal,
}

impl Error {
    pub fn get_status(&self) -> hyper::StatusCode {
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

fn construct_json_ok_response<U: serde::Serialize>(
    data: &U,
) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
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
                            log::error!("Error serving connection: {err:?}");
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
) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
    let span = tracing::span!(
        tracing::Level::INFO,
        "request",
        method = ?req.method(),
        uri = ?req.uri(),
        headers = ?req.headers()
    );
    async move {
        let r = match (req.method(), req.uri().path()) {
            (&hyper::Method::GET, "/status") => handler::status::get(req, state).await,
            (&hyper::Method::GET, "/status/machines") => {
                handler::status::machines(req, state).await
            }
            (&hyper::Method::GET, "/status/jobsets") => handler::status::jobsets(req, state),
            (&hyper::Method::GET, "/status/builds") => handler::status::builds(req, state),
            (&hyper::Method::GET, "/status/steps") => handler::status::steps(req, state),
            (&hyper::Method::GET, "/status/runnable") => handler::status::runnable(req, state),
            (&hyper::Method::GET, "/status/queues") => handler::status::queues(req, state).await,
            (&hyper::Method::GET, "/status/queues/jobs") => {
                handler::status::queue_jobs(req, state).await
            }
            (&hyper::Method::GET, "/status/queues/scheduled") => {
                handler::status::queue_scheduled(req, state).await
            }
            (&hyper::Method::POST, "/dump_status") => handler::dump_status::post(req, state).await,
            (&hyper::Method::PUT, "/build") => handler::build::put(req, state).await,
            (&hyper::Method::GET, "/metrics") => handler::metrics::get(req, state).await,
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
        use bytes::Bytes;
        use http_body_util::combinators::BoxBody;

        use super::super::{Error, construct_json_ok_response};
        use crate::{io, state::State};

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn get(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let queue_stats = io::QueueRunnerStats::new(state.clone()).await;
            let sort_fn = state.config.get_sort_fn();
            let free_fn = state.config.get_free_fn();
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
            let jobsets = {
                let jobsets = state.jobsets.read();
                jobsets
                    .values()
                    .map(|v| (v.full_name(), v.clone().into()))
                    .collect()
            };
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

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn machines(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let sort_fn = state.config.get_sort_fn();
            let free_fn = state.config.get_free_fn();
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

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub fn jobsets(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let jobsets = {
                let jobsets = state.jobsets.read();
                jobsets
                    .values()
                    .map(|v| (v.full_name(), v.clone().into()))
                    .collect()
            };
            construct_json_ok_response(&io::JobsetsResponse::new(jobsets))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub fn builds(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let builds: Vec<io::Build> = {
                state
                    .builds
                    .read()
                    .values()
                    .map(|v| v.clone().into())
                    .collect()
            };
            construct_json_ok_response(&io::BuildsResponse::new(builds))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub fn steps(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let steps: Vec<io::Step> = {
                state
                    .steps
                    .read()
                    .values()
                    .filter_map(std::sync::Weak::upgrade)
                    .map(Into::into)
                    .collect()
            };
            construct_json_ok_response(&io::StepsResponse::new(steps))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub fn runnable(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let steps: Vec<io::Step> = {
                state
                    .steps
                    .read()
                    .values()
                    .filter_map(std::sync::Weak::upgrade)
                    .filter(|v| v.get_runnable())
                    .map(Into::into)
                    .collect()
            };
            construct_json_ok_response(&io::StepsResponse::new(steps))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn queues(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let queues = state
                .queues
                .read()
                .await
                .iter()
                .map(|(s, q)| {
                    (
                        s.clone(),
                        q.clone_inner()
                            .into_iter()
                            .filter_map(|v| v.upgrade().map(Into::into))
                            .collect(),
                    )
                })
                .collect();
            construct_json_ok_response(&io::QueueResponse::new(queues))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn queue_jobs(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let stepinfos = state
                .queues
                .read()
                .await
                .get_jobs()
                .into_iter()
                .map(Into::into)
                .collect();
            construct_json_ok_response(&io::StepInfoResponse::new(stepinfos))
        }

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn queue_scheduled(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let stepinfos = state
                .queues
                .read()
                .await
                .get_scheduled()
                .into_iter()
                .map(Into::into)
                .collect();
            construct_json_ok_response(&io::StepInfoResponse::new(stepinfos))
        }
    }

    pub mod dump_status {
        use bytes::Bytes;
        use http_body_util::combinators::BoxBody;

        use super::super::{Error, construct_json_ok_response};
        use crate::{io, state::State};

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn post(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let mut db = state.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            tx.notify_dump_status().await?;
            tx.commit().await?;
            construct_json_ok_response(&io::Empty {})
        }
    }

    pub mod build {
        use bytes::{Buf as _, Bytes};
        use http_body_util::{BodyExt, combinators::BoxBody};

        use super::super::{Error, construct_json_ok_response};
        use crate::{io, state::State};

        #[tracing::instrument(skip(req, state), err)]
        pub async fn put(
            req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
            let whole_body = req.collect().await?.aggregate();
            let data: io::BuildPayload = serde_json::from_reader(whole_body.reader())?;

            state
                .queue_one_build(data.jobset_id, &nix_utils::StorePath::new(&data.drv))
                .await?;
            construct_json_ok_response(&io::Empty {})
        }
    }

    pub mod metrics {
        use bytes::Bytes;
        use http_body_util::combinators::BoxBody;

        use super::super::{Error, full};
        use crate::state::State;

        #[allow(clippy::no_effect_underscore_binding)]
        #[tracing::instrument(skip(_req, state), err)]
        pub async fn get(
            _req: hyper::Request<hyper::body::Incoming>,
            state: std::sync::Arc<State>,
        ) -> Result<hyper::Response<BoxBody<Bytes, hyper::Error>>, Error> {
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
