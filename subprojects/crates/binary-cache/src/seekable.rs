//! Seekable zstd compression for NARs.
//!
//! The output is a sequence of independent zstd frames, followed by a seek
//! table in a skippable frame, in the [zstd seekable format]. A new frame
//! starts at the first NAR directory entry after [`MIN_FRAME_SIZE`] bytes of
//! NAR, and after at most [`MAX_FRAME_SIZE`] bytes of NAR. Thus a NAR that is
//! smaller than [`MIN_FRAME_SIZE`] is one frame. A client that has the `narOffset`
//! of a file from the `.ls` listing can use the seek table to find the frames
//! that hold the file, and get them with an HTTP range request instead of the
//! full NAR.
//!
//! RFC 8878 section 3.1 makes concatenated frames valid zstd, and decoders skip
//! skippable frames. Thus decoders that do not know the seek table read the
//! output as one NAR. A decoder must continue after the end of the first
//! frame, see `multiple_members` in `async-compression`.
//!
//! [zstd seekable format]: https://github.com/facebook/zstd/blob/dev/contrib/seekable_format/zstd_seekable_compression_format.md

use std::{
    io,
    pin::Pin,
    task::{Context, Poll, ready},
};

use tokio::io::{AsyncBufRead, AsyncRead, ReadBuf};
use zstd_safe::{CCtx, InBuffer, OutBuffer, seekable::SeekableCStream};

/// Minimum NAR bytes in a frame before a directory entry starts a new frame.
///
/// Each frame starts with no compression history, so zstd cannot use matches
/// in earlier frames. Small frames make the NAR larger, mostly when files
/// near each other are similar, for example binaries that contain the same
/// code. Large frames make a client get more bytes for one file.
///
/// We measured this on 145 NARs from a NixOS system closure, with zstd level
/// 3, against one frame for each NAR. With 8 MiB, the total size increased by
/// less than 0.5%, and no NAR increased by more than 6%. With 4 MiB, the
/// total increased by up to 0.8%, and one NAR increased by 19%. A frame at
/// each entry of depth 2 or less increased the total by up to 2.6%, and some
/// small NARs by more than 100%.
pub(crate) const MIN_FRAME_SIZE: u64 = 8 * 1024 * 1024;

/// Maximum NAR bytes in one frame. This is the frame size that Nix uses for
/// zstd, see <https://github.com/NixOS/nix/pull/15550>.
pub(crate) const MAX_FRAME_SIZE: u64 = 16 * 1024 * 1024;

/// Maximum NAR bytes that one `poll_read` takes from the inner reader.
const STEP: usize = 128 * 1024;

/// Longest structure token in a NAR (`nix-archive-1`), rounded up.
const MAX_WORD: usize = 16;

/// Compresses a NAR to seekable zstd. See the [module documentation](self).
pub(crate) struct SeekableZstdEncoder<R> {
    inner: R,
    cstream: SeekableCStream,
    scanner: NarScanner,
    /// NAR bytes from `inner` that are not compressed yet. They start at NAR
    /// offset `held_start`.
    held: Vec<u8>,
    held_start: u64,
    /// Frame starts that the scanner found in `held`.
    cuts: Vec<u64>,
    /// NAR bytes in the current frame.
    frame_len: u64,
    min_frame: u64,
    max_frame: u64,
    /// Compressed bytes that `poll_read` did not return yet.
    out: Vec<u8>,
    out_pos: usize,
    /// An initialization error, returned by the first `poll_read`.
    error: Option<io::Error>,
    done: bool,
}

fn zstd_error(code: usize) -> io::Error {
    io::Error::other(zstd_safe::get_error_name(code))
}

/// Gives the zstd level that `async-compression` uses for `level`.
fn zstd_level(level: async_compression::Level) -> i32 {
    use async_compression::Level;
    let (min, max) = (zstd_safe::min_c_level(), zstd_safe::max_c_level());
    match level {
        Level::Fastest => 1,
        Level::Best => max,
        Level::Precise(level) => level.clamp(min, max),
        _ => zstd_safe::CLEVEL_DEFAULT,
    }
}

impl<R> SeekableZstdEncoder<R> {
    pub(crate) fn new(inner: R, level: async_compression::Level) -> Self {
        Self::with_frame_sizes(inner, level, MIN_FRAME_SIZE, MAX_FRAME_SIZE)
    }

    fn with_frame_sizes(
        inner: R,
        level: async_compression::Level,
        min_frame: u64,
        max_frame: u64,
    ) -> Self {
        let mut cstream = SeekableCStream::create();
        // A maximum of 0 selects the library maximum (1 GiB). This encoder
        // ends frames at `max_frame` itself: when the library ends a frame
        // because of its maximum, it does not tell if the frame needs more
        // output space.
        let error = cstream
            .init(zstd_level(level), false, 0)
            .err()
            .map(zstd_error);
        Self {
            inner,
            cstream,
            scanner: NarScanner::default(),
            held: Vec::new(),
            held_start: 0,
            cuts: Vec::new(),
            frame_len: 0,
            min_frame,
            max_frame: max_frame.max(1),
            out: Vec::new(),
            out_pos: 0,
            error,
            done: false,
        }
    }

    /// Compresses the held bytes up to NAR offset `upto`. Starts a new frame
    /// at each cut where the current frame has at least `min_frame` bytes. The
    /// scanner finds no cut after `upto`.
    fn compress_held(&mut self, upto: u64) -> io::Result<()> {
        let (start, len) = (self.held_start, self.held.len());
        let index = |offset: u64| {
            offset
                .checked_sub(start)
                .and_then(|i| usize::try_from(i).ok())
                .filter(|&i| i <= len)
                .ok_or_else(|| io::Error::other("seekable zstd: offset outside of held bytes"))
        };
        let upto = index(upto)?;
        let mut held = std::mem::take(&mut self.held);
        let mut from = 0;
        for cut in std::mem::take(&mut self.cuts) {
            let at = index(cut)?;
            self.feed(&held[from..at])?;
            if self.frame_len >= self.min_frame {
                self.end_frame()?;
            }
            from = at;
        }
        self.feed(&held[from..upto])?;
        held.drain(..upto);
        self.held = held;
        self.held_start += upto as u64;
        Ok(())
    }

    /// Compresses `data` into the current frame. Starts a new frame first if
    /// the current frame has `max_frame` bytes.
    fn feed(&mut self, mut data: &[u8]) -> io::Result<()> {
        while !data.is_empty() {
            if self.frame_len >= self.max_frame {
                self.end_frame()?;
            }
            let room = usize::try_from(self.max_frame - self.frame_len).unwrap_or(usize::MAX);
            let (now, rest) = data.split_at(room.min(data.len()));
            let mut input = InBuffer::around(now);
            while input.pos() < now.len() {
                self.out.reserve(CCtx::out_size());
                let pos = self.out.len();
                let mut output = OutBuffer::around_pos(&mut self.out, pos);
                self.cstream
                    .compress_stream(&mut output, &mut input)
                    .map_err(zstd_error)?;
            }
            self.frame_len += now.len() as u64;
            data = rest;
        }
        Ok(())
    }

    /// Ends the current frame, if it is not empty.
    fn end_frame(&mut self) -> io::Result<()> {
        if self.frame_len == 0 {
            return Ok(());
        }
        loop {
            self.out.reserve(CCtx::out_size());
            let pos = self.out.len();
            let mut output = OutBuffer::around_pos(&mut self.out, pos);
            if self.cstream.end_frame(&mut output).map_err(zstd_error)? == 0 {
                break;
            }
        }
        self.frame_len = 0;
        Ok(())
    }

    /// Compresses all held bytes, ends the last frame and writes the seek
    /// table.
    fn finish(&mut self) -> io::Result<()> {
        let end = self.held_start + self.held.len() as u64;
        self.compress_held(end)?;
        loop {
            self.out.reserve(CCtx::out_size());
            let pos = self.out.len();
            let mut output = OutBuffer::around_pos(&mut self.out, pos);
            if self.cstream.end_stream(&mut output).map_err(zstd_error)? == 0 {
                break;
            }
        }
        self.done = true;
        Ok(())
    }
}

impl<R: AsyncBufRead + Unpin> AsyncRead for SeekableZstdEncoder<R> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if let Some(e) = this.error.take() {
            return Poll::Ready(Err(e));
        }
        loop {
            if this.out_pos < this.out.len() {
                let n = buf.remaining().min(this.out.len() - this.out_pos);
                buf.put_slice(&this.out[this.out_pos..this.out_pos + n]);
                this.out_pos += n;
                return Poll::Ready(Ok(()));
            }
            this.out.clear();
            this.out_pos = 0;
            if this.done {
                return Poll::Ready(Ok(()));
            }

            let chunk = ready!(Pin::new(&mut this.inner).poll_fill_buf(cx))?;
            if chunk.is_empty() {
                this.finish()?;
                continue;
            }
            let n = chunk.len().min(STEP);
            let start = this.held.len();
            this.held.extend_from_slice(&chunk[..n]);
            Pin::new(&mut this.inner).consume(n);
            this.scanner.scan(&this.held[start..], &mut this.cuts);
            let safe = this.scanner.safe();
            this.compress_held(safe)?;
        }
    }
}

/// Finds the NAR offsets where a new frame starts.
///
/// A NAR is a sequence of strings. Each string has a 64-bit little-endian
/// length, the bytes, and zero padding to a multiple of 8 bytes. A string is
/// a structure token (`(`, `)`, `entry`, `name`, ...), or a value: the string
/// after `type`, `name`, `target`, `contents` or `executable`. The scanner
/// reads the structure tokens to find the `entry` tokens. Each `entry` token
/// is a possible frame start.
///
/// The scanner does not validate the NAR. On an incorrect NAR, the frames are
/// at incorrect offsets, but the compressed data is correct.
#[derive(Default)]
struct NarScanner {
    /// NAR offset of the next byte to scan.
    pos: u64,
    /// NAR offset of the string that is in progress.
    token_start: u64,
    /// The length field of the string, while it is not complete.
    len_buf: [u8; 8],
    len_have: usize,
    /// Bytes of the string that are not scanned yet, padding included. `None`
    /// while the length field is not complete.
    left: Option<u64>,
    /// The string is a value, not a structure token.
    value: bool,
    /// The next string is a value.
    next_is_value: bool,
    /// The bytes of a structure token, if it is not longer than `MAX_WORD`.
    word: Option<([u8; MAX_WORD], usize)>,
    word_have: usize,
}

impl NarScanner {
    /// Scans the next NAR bytes, and adds the NAR offset of each `entry`
    /// token to `cuts`.
    fn scan(&mut self, data: &[u8], cuts: &mut Vec<u64>) {
        let mut i = 0;
        while i < data.len() {
            let avail = data.len() - i;
            match self.left {
                None => {
                    if self.len_have == 0 {
                        self.token_start = self.pos;
                        self.value = self.next_is_value;
                    }
                    let take = (8 - self.len_have).min(avail);
                    self.len_buf[self.len_have..self.len_have + take]
                        .copy_from_slice(&data[i..i + take]);
                    self.len_have += take;
                    i += take;
                    self.pos += take as u64;
                    if self.len_have == 8 {
                        self.len_have = 0;
                        let len = u64::from_le_bytes(self.len_buf);
                        self.word = match usize::try_from(len) {
                            Ok(len) if !self.value && len <= MAX_WORD => Some(([0; MAX_WORD], len)),
                            _ => None,
                        };
                        self.word_have = 0;
                        let padded = len.checked_next_multiple_of(8).unwrap_or(u64::MAX);
                        self.left = Some(padded);
                        if padded == 0 {
                            self.end_token(cuts);
                        }
                    }
                }
                Some(left) => {
                    let take = usize::try_from(left).map_or(avail, |left| left.min(avail));
                    if let Some((word, len)) = &mut self.word
                        && self.word_have < *len
                    {
                        let k = (*len - self.word_have).min(take);
                        word[self.word_have..self.word_have + k].copy_from_slice(&data[i..i + k]);
                        self.word_have += k;
                    }
                    i += take;
                    self.pos += take as u64;
                    let left = left - take as u64;
                    self.left = Some(left);
                    if left == 0 {
                        self.end_token(cuts);
                    }
                }
            }
        }
    }

    fn end_token(&mut self, cuts: &mut Vec<u64>) {
        self.left = None;
        let word = match &self.word {
            Some((word, len)) if !self.value => &word[..*len],
            _ => &[][..],
        };
        if word == b"entry" {
            cuts.push(self.token_start);
        }
        self.next_is_value = !self.value
            && matches!(
                word,
                b"type" | b"name" | b"target" | b"contents" | b"executable"
            );
    }

    /// Gives the NAR offset before which the scanner will find no more
    /// `entry` tokens.
    const fn safe(&self) -> u64 {
        let in_word = match self.left {
            None => self.len_have > 0,
            Some(_) => self.word.is_some() && !self.value,
        };
        if in_word { self.token_start } else { self.pos }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt as _;

    const SKIPPABLE_MAGIC: u32 = 0x184D_2A5E;
    const SEEKABLE_MAGIC: u32 = 0x8F92_EAB1;

    fn u32_at(b: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(b[at..at + 4].try_into().expect("4 bytes"))
    }

    /// Parses the seek table independently of the zstd library. Gives the
    /// (compressed, decompressed) size of each frame.
    fn seek_table(z: &[u8]) -> Vec<(usize, usize)> {
        let footer = z.len() - 9;
        assert_eq!(u32_at(z, footer + 5), SEEKABLE_MAGIC);
        assert_eq!(z[footer + 4], 0, "no checksums, no reserved bits");
        let n = u32_at(z, footer) as usize;
        let table = footer - 8 * n;
        assert_eq!(u32_at(z, table - 8), SKIPPABLE_MAGIC);
        assert_eq!(u32_at(z, table - 4) as usize, 8 * n + 9);
        (0..n)
            .map(|i| {
                let e = table + 8 * i;
                (u32_at(z, e) as usize, u32_at(z, e + 4) as usize)
            })
            .collect()
    }

    /// A tree with entries at depth 1 to 3, and names, contents and link
    /// targets that look like structure tokens. Gives the number of entries.
    fn make_tree() -> (tempfile::TempDir, std::path::PathBuf, usize) {
        use fs_err::os::unix::fs::symlink;
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path().join("out");
        let w = |p: &str, c: &[u8]| fs_err::write(root.join(p), c).expect("write");
        for d in ["bin", "share", "share/deep", "share/deep/deeper"] {
            fs_err::create_dir_all(root.join(d)).expect("mkdir");
        }
        w("bin/hello", b"#!/bin/sh\necho hello\n");
        fs_err::set_permissions(
            root.join("bin/hello"),
            std::fs::Permissions::from_mode(0o755),
        )
        .expect("chmod");
        w("bin/entry", b"entry");
        w("(", b"(");
        w(")", b")");
        w("share/deep/a", &[7; 3000]);
        w("share/deep/deeper/entry", b"entry");
        symlink("entry", root.join("share/entry")).expect("symlink");
        symlink("a", root.join("share/deep/b")).expect("symlink");
        let big: Vec<u8> = (0..40_000u32).map(|i| (i * 7919 % 251) as u8).collect();
        w("big", &big);
        // (, ), big, bin, bin/entry, bin/hello, share, share/deep,
        // share/deep/a, share/deep/b, share/deep/deeper,
        // share/deep/deeper/entry, share/entry.
        (dir, root, 13)
    }

    async fn nar_of(path: &std::path::Path) -> Vec<u8> {
        let mut r = tokio_util::io::StreamReader::new(harmonia_file_nar::NarByteStream::new(
            path.to_path_buf(),
        ));
        let mut nar = Vec::new();
        r.read_to_end(&mut nar).await.expect("read nar");
        nar
    }

    async fn encode(nar: &[u8], read_size: usize, min_frame: u64, max_frame: u64) -> Vec<u8> {
        let reader = tokio::io::BufReader::with_capacity(read_size, nar);
        let mut enc = SeekableZstdEncoder::with_frame_sizes(
            reader,
            async_compression::Level::Default,
            min_frame,
            max_frame,
        );
        let mut z = Vec::new();
        enc.read_to_end(&mut z).await.expect("encode");
        z
    }

    fn frame_starts(table: &[(usize, usize)]) -> Vec<usize> {
        table
            .iter()
            .scan(0, |at, &(_, d)| {
                let s = *at;
                *at += d;
                Some(s)
            })
            .collect()
    }

    const ENTRY: &[u8] = b"\x05\0\0\0\0\0\0\0entry\0\0\0";

    /// Gives the NAR offsets of the `entry` tokens. A minimum frame size of 1
    /// starts a frame at each entry.
    async fn entries(nar: &[u8]) -> Vec<usize> {
        frame_starts(&seek_table(&encode(nar, 8192, 1, MAX_FRAME_SIZE).await))[1..].to_vec()
    }

    #[tokio::test]
    async fn frames_start_at_entries() {
        let (_dir, root, n_entries) = make_tree();
        let nar = nar_of(&root).await;
        let z = encode(&nar, 8192, 1, MAX_FRAME_SIZE).await;
        let table = seek_table(&z);

        let starts = frame_starts(&table);
        assert_eq!(starts[0], 0);
        for &s in &starts[1..] {
            assert_eq!(
                &nar[s..s + ENTRY.len()],
                ENTRY,
                "frame at {s} is not an entry"
            );
        }
        assert_eq!(starts.len(), 1 + n_entries);

        // The sizes cover the NAR and the compressed file.
        assert_eq!(table.iter().map(|t| t.1).sum::<usize>(), nar.len());
        let tail = 8 + 8 * table.len() + 9;
        assert_eq!(table.iter().map(|t| t.0).sum::<usize>() + tail, z.len());

        // Each frame decompresses alone to its part of the NAR.
        let mut at = 0;
        for (&(c, d), s) in table.iter().zip(starts) {
            let mut out = Vec::with_capacity(d);
            zstd_safe::decompress(&mut out, &z[at..at + c]).expect("frame");
            assert_eq!(out, nar[s..s + d]);
            at += c;
        }
    }

    #[tokio::test]
    async fn frames_end_at_first_entry_after_min_frame() {
        let (_dir, root, _) = make_tree();
        let nar = nar_of(&root).await;
        let entries = entries(&nar).await;
        let mut counts = Vec::new();
        for min_frame in [100, 1000, 3000, 10_000, 1 << 20] {
            let mut want = vec![0];
            for &e in &entries {
                if e - want.last().expect("not empty") >= min_frame {
                    want.push(e);
                }
            }
            let table = seek_table(&encode(&nar, 8192, min_frame as u64, MAX_FRAME_SIZE).await);
            assert_eq!(frame_starts(&table), want, "minimum {min_frame}");
            counts.push(want.len());
        }
        // The cases are not all the same.
        assert!(counts[0] > counts[2] && counts[2] > 1, "{counts:?}");
        // A NAR that is smaller than the minimum is one frame.
        assert!(nar.len() < 1 << 20);
        assert_eq!(counts.last(), Some(&1));
    }

    #[tokio::test]
    async fn read_size_does_not_change_frames() {
        let (_dir, root, _) = make_tree();
        let nar = nar_of(&root).await;
        for min_frame in [1, 1000] {
            let want = seek_table(&encode(&nar, 1 << 20, min_frame, MAX_FRAME_SIZE).await);
            for read_size in [1, 3, 7, 8, 9, 13, 4096] {
                let got = seek_table(&encode(&nar, read_size, min_frame, MAX_FRAME_SIZE).await);
                let sizes = |t: &[(usize, usize)]| t.iter().map(|t| t.1).collect::<Vec<_>>();
                assert_eq!(
                    sizes(&got),
                    sizes(&want),
                    "read size {read_size}, minimum {min_frame}"
                );
            }
        }
    }

    #[tokio::test]
    async fn frames_are_at_most_max_frame() {
        let (_dir, root, n_entries) = make_tree();
        let nar = nar_of(&root).await;
        let table = seek_table(&encode(&nar, 8192, 1, 4096).await);
        assert!(table.iter().all(|t| t.1 <= 4096));
        assert!(table.len() > 1 + n_entries, "big file is split");
        let starts = frame_starts(&table);
        let at_entry = starts[1..]
            .iter()
            .filter(|&&s| nar[s..s + ENTRY.len()] == *ENTRY)
            .count();
        assert_eq!(at_entry, n_entries);
    }

    #[tokio::test]
    async fn decoder_reads_all_frames() {
        let (_dir, root, _) = make_tree();
        let nar = nar_of(&root).await;
        let z = encode(&nar, 8192, 1, MAX_FRAME_SIZE).await;
        assert!(seek_table(&z).len() > 1);
        let mut dec = crate::Compression::Zstd.get_decompression_fn()(io::Cursor::new(z));
        let mut out = Vec::new();
        dec.read_to_end(&mut out).await.expect("decode");
        assert_eq!(out, nar);
    }

    #[tokio::test]
    async fn empty_input() {
        let z = encode(&[], 8192, MIN_FRAME_SIZE, MAX_FRAME_SIZE).await;
        let mut dec = crate::Compression::Zstd.get_decompression_fn()(io::Cursor::new(z));
        let mut out = Vec::new();
        dec.read_to_end(&mut out).await.expect("decode");
        assert!(out.is_empty());
    }
}
