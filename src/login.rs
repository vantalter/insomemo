//! Launch at Login. The operating system owns this setting, so it is read back
//! from there rather than stored in `state.json`.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]
use std::path::Path;
#[cfg(target_os = "linux")]
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Not available here (macOS 12, or the binary was started outside its app bundle).
    Unsupported,
    Off,
    On,
    /// macOS registered the login item but the user must approve it in System Settings.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    NeedsApproval,
}

impl Status {
    pub fn id(self) -> &'static str {
        match self {
            Status::Unsupported => "unsupported",
            Status::Off => "off",
            Status::On => "on",
            Status::NeedsApproval => "approval",
        }
    }
}

#[cfg(target_os = "macos")]
fn native(action: i32) -> Status {
    match unsafe { crate::native::native_login_item(action) } {
        0 => Status::Off,
        1 => Status::On,
        2 => Status::NeedsApproval,
        _ => Status::Unsupported,
    }
}

#[cfg(target_os = "macos")]
pub fn status() -> Status {
    native(-1)
}

/// Turns launch at login on or off. Asking for it while approval is pending
/// opens System Settings on macOS.
#[cfg(target_os = "macos")]
pub fn set(enabled: bool) -> Result<Status, String> {
    let status = native(enabled as i32);
    match (enabled, status) {
        (true, Status::Off) => Err("macOS did not add Insomemo to Login Items".into()),
        (false, Status::On) => Err("macOS did not remove Insomemo from Login Items".into()),
        _ => Ok(status),
    }
}

/// XDG autostart entry, honoured by GNOME, KDE, Xfce, and other desktops that
/// implement the specification.
#[cfg(target_os = "linux")]
fn desktop_file() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(config.join("autostart").join("insomemo.desktop"))
}

#[cfg(target_os = "linux")]
pub fn status() -> Status {
    match desktop_file() {
        Some(path) if path.exists() => Status::On,
        Some(_) => Status::Off,
        None => Status::Unsupported,
    }
}

#[cfg(target_os = "linux")]
pub fn set(enabled: bool) -> Result<Status, String> {
    let path = desktop_file().ok_or("HOME or XDG_CONFIG_HOME must be set")?;
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    if enabled {
        write_entry(&path, &executable)
    } else {
        remove_entry(&path)
    }
    .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(status())
}

fn write_entry(path: &Path, executable: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap())?;
    std::fs::write(path, entry(executable))
}

fn remove_entry(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

/// A desktop entry that starts this executable, quoted per the Desktop Entry
/// specification so paths with spaces or reserved characters survive.
fn entry(executable: &Path) -> String {
    let mut quoted = String::from('"');
    for c in executable.to_string_lossy().chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted.push('"');
    // Desktop files escape backslashes once more at the string level.
    let exec = quoted.replace('\\', "\\\\");
    format!(
        "[Desktop Entry]\nType=Application\nName=Insomemo\nComment=Remember keyboard layouts for apps and window titles\nExec={exec}\nIcon=input-keyboard\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_line_quotes_reserved_characters() {
        let text = entry(Path::new("/home/a b/$bin/in\"so"));
        assert!(
            text.contains("Exec=\"/home/a b/\\\\$bin/in\\\\\"so\"\n"),
            "{text}"
        );
        assert!(text.starts_with("[Desktop Entry]\n"));
    }

    #[test]
    fn entry_round_trip() {
        let dir = std::env::temp_dir().join(format!("insomemo-login-{}", std::process::id()));
        let path = dir.join("autostart").join("insomemo.desktop");
        write_entry(&path, Path::new("/usr/bin/insomemo")).unwrap();
        assert!(
            std::fs::read_to_string(&path)
                .unwrap()
                .contains("Exec=\"/usr/bin/insomemo\"")
        );
        remove_entry(&path).unwrap();
        remove_entry(&path).unwrap();
        assert!(!path.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
