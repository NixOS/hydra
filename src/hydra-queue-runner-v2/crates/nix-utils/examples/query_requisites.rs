use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let drv = nix_utils::StorePath::new("5g60vyp4cbgwl12pav5apyi571smp62s-hello-2.12.2.drv");
    let ps = store
        .query_requisites(vec![drv.clone()], false)
        .await
        .unwrap();
    for p in ps {
        println!("{}", p.get_full_path());
    }

    println!();
    println!();

    let ps = store.query_requisites(vec![drv], true).await.unwrap();
    for p in ps {
        println!("{}", p.get_full_path());
    }
}
