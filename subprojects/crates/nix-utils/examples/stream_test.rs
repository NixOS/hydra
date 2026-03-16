use bytes::Bytes;
use tokio::io::AsyncReadExt;
use tokio_util::io::StreamReader;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create a stream from an iterator.
    let stream = tokio_stream::iter(vec![
        tokio::io::Result::Ok(Bytes::from_static(&[0, 1, 2, 3])),
        tokio::io::Result::Ok(Bytes::from_static(&[4, 5, 6, 7])),
        tokio::io::Result::Ok(Bytes::from_static(&[8, 9, 10, 11])),
    ]);

    // Convert it to an AsyncRead.
    let mut read = StreamReader::new(stream);

    // Read five bytes from the stream.
    let mut buf = [0; 2];

    loop {
        let read = read.read(&mut buf).await?;
        if read == 0 {
            break;
        }
        println!("{buf:?}");
    }

    Ok(())
}
