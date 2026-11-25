//! Report a Problem: opens GitHub's bug report form, prefilled with facts
//! that identify nothing about the user: Insomemo's version, the platform,
//! the operating system, and the processor. The user reviews the issue and
//! submits it; nothing is sent by the app.

use std::process::Command;

const NEW_ISSUE: &str = "https://github.com/vantalter/insomemo/issues/new";

/// This computer's operating system and processor, with the desktop on Linux.
fn system() -> String {
    let arch = std::env::consts::ARCH;
    if cfg!(target_os = "macos") {
        let version = Command::new("sw_vers")
            .arg("-productVersion")
            .output()
            .ok()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .filter(|version| !version.is_empty())
            .unwrap_or_else(|| "unknown version".into());
        return format!("macOS {version}, {arch}");
    }
    let release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
    let name = release
        .lines()
        .find_map(|line| line.strip_prefix("PRETTY_NAME="))
        .map(|name| name.trim_matches('"').to_owned())
        .unwrap_or_else(|| "Linux".into());
    match std::env::var("XDG_CURRENT_DESKTOP") {
        Ok(desktop) if !desktop.is_empty() => format!("{name}, {arch}, {desktop}"),
        _ => format!("{name}, {arch}"),
    }
}

/// Percent-encodes a query value, leaving only unreserved characters.
fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// The bug report form, prefilled through its fields' ids. `platform` is one
/// of the form's Platform options, such as "macOS" or "Linux X11".
pub fn url(platform: &str) -> String {
    build(platform, &system())
}

fn build(platform: &str, system: &str) -> String {
    let fields = [
        ("template", "bug_report.yml".to_owned()),
        ("platform", platform.to_owned()),
        ("version", format!("insomemo {}", env!("CARGO_PKG_VERSION"))),
        ("system", system.to_owned()),
    ];
    let query: Vec<String> = fields
        .iter()
        .map(|(name, value)| format!("{name}={}", encode(value)))
        .collect();
    format!("{NEW_ISSUE}?{}", query.join("&"))
}

/// Opens the form in the default browser, without waiting for it.
pub fn open(url: &str) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let url = url.to_owned();
    // Waited for on its own thread, so the opener does not linger as a zombie.
    std::thread::spawn(move || {
        if let Err(e) = Command::new(opener).arg(&url).status() {
            eprintln!("insomemo: cannot open {url}: {e}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_form_is_prefilled_with_versions_only() {
        let url = build("Linux X11", "Ubuntu 24.04 LTS, x86_64, X-Cinnamon");
        assert!(url.starts_with(
            "https://github.com/vantalter/insomemo/issues/new?template=bug_report.yml&"
        ));
        assert!(url.contains("&platform=Linux%20X11&"));
        assert!(url.contains(&format!(
            "&version=insomemo%20{}&",
            env!("CARGO_PKG_VERSION")
        )));
        assert!(url.ends_with("&system=Ubuntu%2024.04%20LTS%2C%20x86_64%2C%20X-Cinnamon"));
    }

    #[test]
    fn the_platforms_and_fields_match_the_form() {
        let form = include_str!("../.github/ISSUE_TEMPLATE/bug_report.yml");
        for platform in ["macOS", "Linux X11", "Linux Sway", "Linux Hyprland"] {
            assert!(
                form.contains(&format!("        - {platform}\n")),
                "{platform}"
            );
        }
        for id in ["platform", "version", "system"] {
            assert!(form.contains(&format!("    id: {id}\n")), "{id}");
        }
    }
}
