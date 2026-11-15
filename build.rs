fn main() {
    println!("cargo:rerun-if-changed=native");
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut build = cc::Build::new();
    build.include("native").warnings(true);
    let mut libraries = Vec::new();
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
    match target.as_str() {
        "macos" => {
            build.flag("-mmacosx-version-min=12.0");
            build.file("native/macos.m").flag("-fobjc-arc");
            for framework in [
                "AppKit",
                "ApplicationServices",
                "Carbon",
                "ServiceManagement",
            ] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
        "linux" => {
            for package in [
                "gio-unix-2.0",
                "x11",
                "json-glib-1.0",
                "xkbcommon",
                "gdk-pixbuf-2.0",
            ] {
                let lib = pkg_config::Config::new()
                    .cargo_metadata(false)
                    .probe(package)
                    .unwrap_or_else(|e| panic!("Missing {package} development files: {e}"));
                for path in &lib.include_paths {
                    build.include(path);
                }
                libraries.push(lib);
            }
            build
                .files(["native/linux.c", "native/linux_icon.c"])
                .flag("-std=c11");
        }
        _ => panic!("insomemo supports macOS and Linux"),
    }
    build.compile("insomemo_native");
    // GNU ld resolves left to right: system libraries must follow the static
    // native library that references them.
    for lib in libraries {
        for path in lib.link_paths {
            println!("cargo:rustc-link-search=native={}", path.display());
        }
        for name in lib.libs {
            println!("cargo:rustc-link-lib={name}");
        }
    }
}
