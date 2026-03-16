// Based on https://heikoseeberger.de/2023-08-28-dist-tracing-3/

#[cfg(feature = "otel")]
use opentelemetry::{global, propagation::Injector};
#[cfg(feature = "otel")]
use tracing_opentelemetry::OpenTelemetrySpanExt;

pub fn accept_trace<B>(request: http::Request<B>) -> http::Request<B> {
    #[cfg(feature = "otel")]
    {
        let parent_context = global::get_text_map_propagator(|propagator| {
            propagator.extract(&opentelemetry_http::HeaderExtractor(request.headers()))
        });
        let _ = tracing::Span::current().set_parent(parent_context);
    }
    request
}

#[cfg(feature = "otel")]
struct MetadataInjector<'a>(&'a mut tonic::metadata::MetadataMap);

#[cfg(feature = "otel")]
impl Injector for MetadataInjector<'_> {
    fn set(&mut self, key: &str, value: String) {
        use tonic::metadata::{MetadataKey, MetadataValue};
        use tracing::warn;

        match MetadataKey::from_bytes(key.as_bytes()) {
            Ok(key) => match MetadataValue::try_from(&value) {
                Ok(value) => {
                    self.0.insert(key, value);
                }
                Err(error) => warn!(value, error = format!("{error:#}"), "parse metadata value"),
            },
            Err(error) => warn!(key, error = format!("{error:#}"), "parse metadata key"),
        }
    }
}

#[allow(unused_mut)]
pub fn send_trace<T>(
    mut request: tonic::Request<T>,
) -> Result<tonic::Request<T>, Box<tonic::Status>> {
    #[cfg(feature = "otel")]
    {
        global::get_text_map_propagator(|propagator| {
            let context = tracing::Span::current().context();
            propagator.inject_context(&context, &mut MetadataInjector(request.metadata_mut()));
        });
    }
    Ok(request)
}
