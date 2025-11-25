use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use nix_utils::{self, BaseStore as _};

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let file = tokio::fs::File::open("/tmp/test.nar").await.unwrap();
    let mut reader = tokio::io::BufReader::new(file);

    println!("Importing test.nar == 5g60vyp4cbgwl12pav5apyi571smp62s-hello-2.12.2.drv");
    let (mut rx, tx) = tokio::net::unix::pipe::pipe().unwrap();

    tokio::spawn(async move {
        let mut buf: [u8; 1] = [0; 1];
        loop {
            let s = reader.read(&mut buf).await.unwrap();
            if s == 0 {
                break;
            }
            let _ = rx.write(&buf).await.unwrap();
        }
        let _ = rx.shutdown().await;
        drop(rx);
    });
    tokio::task::spawn_blocking(move || async move {
        store
            .import_paths_with_fd(tx.into_blocking_fd().unwrap(), false)
            .unwrap();
    })
    .await
    .unwrap()
    .await;
}
