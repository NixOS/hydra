use sha2::{Digest as _, Sha256};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, ReadBuf};
use tokio::sync::OnceCell;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Cannot finalize: stream has not been completed")]
    NotCompleted,
}

#[derive(Debug, Clone)]
pub struct HashResult {
    inner: Arc<OnceCell<(sha2::digest::Output<Sha256>, usize)>>,
}

impl HashResult {
    fn new() -> Self {
        Self {
            inner: Arc::new(OnceCell::new()),
        }
    }

    pub fn get(&self) -> Result<(sha2::digest::Output<Sha256>, usize), Error> {
        Ok(self.inner.get().ok_or(Error::NotCompleted)?.to_owned())
    }
}

#[derive(Debug)]
pub struct HashingReader<R> {
    inner: R,
    hasher: Option<Sha256>,
    size: usize,
    hash_result: HashResult,
}

impl<R> Unpin for HashingReader<R> where R: Unpin {}

impl<R: AsyncRead + Unpin + Send> HashingReader<R> {
    pub fn new(reader: R) -> (Self, HashResult) {
        let res = HashResult::new();
        (
            Self {
                inner: reader,
                hasher: Some(Sha256::new()),
                size: 0,
                hash_result: res.clone(),
            },
            res,
        )
    }

    pub fn finalize(&self) -> Result<(sha2::digest::Output<Sha256>, usize), Error> {
        self.hash_result.get()
    }
}

impl<R: AsyncRead + Unpin + Send> AsyncRead for HashingReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let filled_len = buf.filled().len();
        match Pin::new(&mut self.inner).poll_read(cx, buf) {
            Poll::Ready(Ok(())) => {
                let new_data = &buf.filled()[filled_len..];
                if !new_data.is_empty() {
                    if let Some(hasher) = self.hasher.as_mut() {
                        hasher.update(new_data);
                    }
                    self.size += new_data.len();
                }

                if new_data.is_empty()
                    && let Some(hasher) = self.hasher.take()
                {
                    let _ = self.hash_result.inner.set((hasher.finalize(), self.size));
                }
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
            Poll::Pending => Poll::Pending,
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use bytes::Bytes;
    use sha2::{Digest, Sha256};
    use std::io::Cursor;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn test_hashing_reader_empty_data() {
        let data = b"";
        let cursor = Cursor::new(data.to_vec());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        let mut buffer = Vec::new();
        let bytes_read = hashing_reader.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(bytes_read, 0);
        assert_eq!(buffer, b"");

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, 0);

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_small_data() {
        let data = b"Hello, world!";
        let cursor = Cursor::new(data.to_vec());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        let mut buffer = Vec::new();
        let bytes_read = hashing_reader.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(bytes_read, data.len());
        assert_eq!(buffer, data);

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, data.len());

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_large_data() {
        // Create 1MB of test data
        let data = vec![0x42u8; 1024 * 1024];
        let cursor = Cursor::new(data.clone());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        let mut buffer = Vec::new();
        let bytes_read = hashing_reader.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(bytes_read, data.len());
        assert_eq!(buffer, data);

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, data.len());

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(&data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_partial_reads() {
        let data = b"The quick brown fox jumps over the lazy dog";
        let cursor = Cursor::new(data.to_vec());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        let mut buffer = [0u8; 10];
        let mut total_read = 0;
        let mut all_data = Vec::new();

        // Read in chunks
        loop {
            let bytes_read = hashing_reader.read(&mut buffer).await.unwrap();
            if bytes_read == 0 {
                break;
            }
            total_read += bytes_read;
            all_data.extend_from_slice(&buffer[..bytes_read]);
        }

        assert_eq!(total_read, data.len());
        assert_eq!(all_data, data);

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, data.len());

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_exact_buffer_size() {
        let data = b"Exactly 20 bytes!!";
        let cursor = Cursor::new(data.to_vec());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        let mut buffer = [0u8; 20];
        let bytes_read = hashing_reader.read(&mut buffer).await.unwrap();

        assert_eq!(bytes_read, data.len());
        assert_eq!(&buffer[..bytes_read], data);

        // Try to read more - should get EOF
        let mut buffer2 = [0u8; 10];
        let bytes_read2 = hashing_reader.read(&mut buffer2).await.unwrap();
        assert_eq!(bytes_read2, 0);

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, data.len());

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_different_data_patterns() {
        let test_cases = vec![
            vec![0u8; 100],                      // All zeros
            vec![0xFFu8; 100],                   // All 0xFF
            (0..=255).collect::<Vec<u8>>(),      // All byte values
            vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10], // Small sequence
        ];

        for data in test_cases {
            let cursor = Cursor::new(data.clone());
            let (mut hashing_reader, _) = HashingReader::new(cursor);

            let mut buffer = Vec::new();
            hashing_reader.read_to_end(&mut buffer).await.unwrap();

            let (hash, size) = hashing_reader.finalize().unwrap();
            assert_eq!(size, data.len());
            assert_eq!(buffer, data);

            // Verify against direct computation
            let mut direct_hasher = Sha256::new();
            direct_hasher.update(&data);
            let expected_hash = direct_hasher.finalize();
            assert_eq!(hash, expected_hash);
        }
    }

    #[tokio::test]
    async fn test_hashing_reader_with_async_stream() {
        use tokio_stream::wrappers::ReceiverStream;

        let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(10);
        let data = b"Async stream test data";

        // Spawn a task to send data
        let data_clone = data.to_vec();
        tokio::spawn(async move {
            for chunk in data_clone.chunks(5) {
                tx.send(Ok(Bytes::copy_from_slice(chunk))).await.unwrap();
            }
        });

        let stream = ReceiverStream::new(rx);
        let reader = tokio_util::io::StreamReader::new(stream);
        let (mut hashing_reader, _) = HashingReader::new(reader);

        let mut buffer = Vec::new();
        hashing_reader.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(buffer, data);

        let (hash, size) = hashing_reader.finalize().unwrap();
        assert_eq!(size, data.len());

        // Verify against direct computation
        let mut direct_hasher = Sha256::new();
        direct_hasher.update(data);
        let expected_hash = direct_hasher.finalize();
        assert_eq!(hash, expected_hash);
    }

    #[tokio::test]
    async fn test_hashing_reader_finalize_before_completion() {
        let data = b"Hello, world!";
        let cursor = Cursor::new(data.to_vec());
        let (hashing_reader, _) = HashingReader::new(cursor);

        // Try to finalize before reading any data
        let result = hashing_reader.finalize();
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Error::NotCompleted));
    }

    #[tokio::test]
    async fn test_hashing_reader_finalize_partial_read() {
        let data = b"Hello, world!";
        let cursor = Cursor::new(data.to_vec());
        let (mut hashing_reader, _) = HashingReader::new(cursor);

        // Read only part of the data
        let mut buffer = [0u8; 5];
        let bytes_read = hashing_reader.read(&mut buffer).await.unwrap();
        assert_eq!(bytes_read, 5);

        // Try to finalize before reading all data
        let result = hashing_reader.finalize();
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Error::NotCompleted));
    }
}
