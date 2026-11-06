fn main() {
    println!("cargo:rerun-if-changed=native");
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut build = cc::Build::new();
    build.include("native").warnings(true);
    match target.as_str() {
        "macos" => {
            build.flag("-mmacosx-version-min=12.0");
            build.file("native/macos.m").flag("-fobjc-arc");
            for framework in ["AppKit", "ApplicationServices", "Carbon"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
        "linux" => {
            for package in ["gio-unix-2.0", "x11", "json-glib-1.0", "xkbcommon"] {
                let lib = pkg_config::Config::new()
                    .probe(package)
                    .unwrap_or_else(|e| panic!("Missing {package} development files: {e}"));
                for path in lib.include_paths {
                    build.include(path);
                }
            }
            build.file("native/linux.c").flag("-std=c11");
        }
        _ => panic!("input-switcher supports macOS and Linux"),
    }
    build.compile("input_switcher_native");
}
