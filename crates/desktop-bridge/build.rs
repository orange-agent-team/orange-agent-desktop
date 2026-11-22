fn main() {
    let crate_dir = std::path::PathBuf::from(
        std::env::var_os("CARGO_MANIFEST_DIR").expect("Cargo manifest directory"),
    );
    let root = crate_dir
        .parent()
        .and_then(std::path::Path::parent)
        .expect("desktop workspace");
    let lock = root.join("config/runtime.lock.json");
    let source: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&lock).expect("runtime lock"))
            .expect("runtime lock JSON");
    let vendor = std::path::Path::new(
        source["vendor_directory"]
            .as_str()
            .expect("pinned vendor directory"),
    );
    assert!(
        vendor.starts_with("vendor")
            && vendor
                .components()
                .all(|part| matches!(part, std::path::Component::Normal(_))),
        "invalid vendored source path"
    );
    let catalog = root
        .join(vendor)
        .join("config/local-model.lock.json")
        .canonicalize()
        .expect("catalog in pinned source");
    assert!(
        catalog.starts_with(root.join("vendor").canonicalize().expect("vendor root"))
            && catalog.is_file(),
        "invalid pinned catalog"
    );
    println!("cargo:rerun-if-changed={}", lock.display());
    println!("cargo:rerun-if-changed={}", catalog.display());
    println!(
        "cargo:rustc-env=ORANGE_DESKTOP_MODEL_CATALOG={}",
        catalog.display()
    );

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // Flutter packages this dylib under the framework install name below.
        // Using it at link time also keeps the Mach-O UUID independent of the build directory.
        // Native Assets can temporarily relocate the debug library under a longer path.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
        println!(
            "cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/orange_desktop_bridge.framework/orange_desktop_bridge"
        );
    }
}
