//! Newtype wrappers for using harmonia store types with prost/tonic.
//!
//! These exist to work around the orphan rule: we cannot implement
//! `prost::Message` for `harmonia_store_core::store_path::StorePath`
//! directly because both the trait and the type are foreign.  Instead,
//! we define thin newtypes here (inside the hydra workspace) and map
//! them via `extern_path` in the prost-build configuration.

use prost::DecodeError;
use prost::bytes::{Buf, BufMut};
use prost::encoding::{self, DecodeContext, WireType};

use nix_utils::StorePath;

/// A [`StorePath`] that implements [`prost::Message`].
///
/// On the wire this is identical to the protobuf message
///
/// ```proto
/// message StorePath { string path = 1; }
/// ```
///
/// where `path` contains the store-path base name (`<hash>-<name>`).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ProtoStorePath(pub StorePath);

impl Default for ProtoStorePath {
    fn default() -> Self {
        Self(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x"
                .parse()
                .expect("hard-coded valid store path"),
        )
    }
}

impl From<StorePath> for ProtoStorePath {
    fn from(p: StorePath) -> Self {
        Self(p)
    }
}

impl From<ProtoStorePath> for StorePath {
    fn from(p: ProtoStorePath) -> StorePath {
        p.0
    }
}

impl std::ops::Deref for ProtoStorePath {
    type Target = StorePath;
    fn deref(&self) -> &StorePath {
        &self.0
    }
}

impl std::fmt::Display for ProtoStorePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl prost::Message for ProtoStorePath {
    fn encode_raw(&self, buf: &mut impl BufMut)
    where
        Self: Sized,
    {
        let s = self.0.to_string();
        encoding::string::encode(1, &s, buf);
    }

    fn merge_field(
        &mut self,
        tag: u32,
        wire_type: WireType,
        buf: &mut impl Buf,
        ctx: DecodeContext,
    ) -> Result<(), DecodeError>
    where
        Self: Sized,
    {
        match tag {
            1 => {
                let mut s = String::new();
                encoding::string::merge(wire_type, &mut s, buf, ctx)?;
                #[allow(deprecated)]
                {
                    self.0 = s
                        .parse()
                        .map_err(|e| DecodeError::new(format!("invalid StorePath: {e}")))?;
                }
                Ok(())
            }
            _ => encoding::skip_field(wire_type, tag, buf, ctx),
        }
    }

    fn encoded_len(&self) -> usize {
        let s = self.0.to_string();
        encoding::string::encoded_len(1, &s)
    }

    fn clear(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn roundtrip() {
        let path: StorePath = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap();
        let proto = ProtoStorePath(path.clone());

        let encoded = proto.encode_to_vec();
        let decoded = ProtoStorePath::decode(&encoded[..]).unwrap();
        assert_eq!(decoded.0, path);
    }

    #[test]
    fn wire_compat_with_generated_message() {
        // Our ProtoStorePath should produce the same bytes as a
        // prost-generated message with `string path = 1;`.
        let path: StorePath = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap();
        let proto = ProtoStorePath(path.clone());

        let encoded = proto.encode_to_vec();

        // Manually encode what the generated struct would produce:
        // tag 1, wire type LengthDelimited, then the string.
        let mut expected = Vec::new();
        let s = path.to_string();
        encoding::string::encode(1, &s, &mut expected);

        assert_eq!(encoded, expected);
    }

    #[test]
    fn nested_message_compat() {
        // When used as a nested message field (tag 2) inside a parent,
        // verify the encoding matches what prost would generate for
        // `message Parent { StorePath sp = 2; }`.
        let path: StorePath = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap();
        let proto = ProtoStorePath(path);

        let mut buf = Vec::new();
        encoding::message::encode(2, &proto, &mut buf);

        // Decode: tag 2 length-delimited, then inner is tag 1 length-delimited string.
        let decoded = ProtoStorePath::decode(&buf[2..]).unwrap(); // skip outer tag+len
        assert_eq!(decoded, proto);
    }
}
