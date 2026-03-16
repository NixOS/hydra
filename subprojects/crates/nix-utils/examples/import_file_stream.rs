use nix_utils::{self, BaseStore as _};

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let file = fs_err::tokio::File::open("/tmp/test3.nar").await.unwrap();
    let stream = tokio_util::io::ReaderStream::new(file);

    store.import_paths(stream, false).await.unwrap();
}
