fn main() {
    println!("cargo:rerun-if-changed=native");
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut build = cc::Build::new();
    build.include("native").warnings(true);
    match target.as_str() {
        "macos" => {
            let icon_path = "assets/TrayTemplate.png";
            println!("cargo:rerun-if-changed={icon_path}");
            let icon = std::fs::read(icon_path).expect("Missing Insomemo tray icon");
            let bytes = icon.iter().map(u8::to_string).collect::<Vec<_>>().join(",");
            let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
            std::fs::write(
                out.join("tray_icon.h"),
                format!("static const unsigned char tray_icon[] = {{{bytes}}};\n"),
            )
            .expect("Cannot embed Insomemo tray icon");
            build.include(out);
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
        _ => panic!("insomemo supports macOS and Linux"),
    }
    build.compile("insomemo_native");
}
