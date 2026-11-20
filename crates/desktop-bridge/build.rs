fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // Flutter packages this dylib under the framework install name below.
        // Using it at link time also keeps the Mach-O UUID independent of the build directory.
        println!(
            "cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/orange_desktop_bridge.framework/orange_desktop_bridge"
        );
    }
}
