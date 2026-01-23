use nix_utils::{self, BaseStore as _};

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<_>>();
    let closure = move |data: &[u8]| {
        let data = Vec::from(data);
        tx.send(data).is_ok()
    };

    let x = tokio::spawn(async move {
        while let Some(x) = rx.recv().await {
            print!("{}", String::from_utf8_lossy(&x));
        }
    });

    tokio::task::spawn_blocking(move || async move {
        store
            .export_paths(
                &[nix_utils::StorePath::new(
                    "5g60vyp4cbgwl12pav5apyi571smp62s-hello-2.12.2.drv",
                )],
                closure,
            )
            .unwrap();
    })
    .await
    .unwrap()
    .await;

    x.await.unwrap();
}
