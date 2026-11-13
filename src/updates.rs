//! Published GitHub releases, checked only on request or while enabled.
use serde_json::Value;
use std::process::Command;

const RELEASES: &str = "https://api.github.com/repos/vantalter/insomemo/releases?per_page=100";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Idle,
    Checking,
    Current,
    Available(String),
    Failed(String),
}

impl Status {
    pub fn label(&self) -> &str {
        match self {
            Self::Idle => "",
            Self::Checking => "Checking for updates…",
            Self::Current => "Insomemo is up to date",
            Self::Available(_) => "Update available — Open Releases…",
            Self::Failed(_) => "Update check failed",
        }
    }
    pub fn detail(&self) -> String {
        match self {
            Self::Available(version) => format!("Version {version} available — Open Releases…"),
            Self::Failed(reason) => format!("Update check failed: {reason}"),
            _ => self.label().to_owned(),
        }
    }
    pub fn can_open(&self) -> bool {
        matches!(self, Self::Available(_))
    }
    pub fn manual_message(&self) -> String {
        match self {
            Self::Current => "Insomemo is up to date.".into(),
            Self::Available(version) => {
                format!("Version {version} is available. Open the tray menu to view releases.")
            }
            Self::Failed(reason) => format!("Could not check for updates: {reason}."),
            _ => String::new(),
        }
    }
}

fn numeric(tag: &str) -> Option<[u64; 3]> {
    let tag = tag.strip_prefix('v').unwrap_or(tag);
    let mut parts = tag.split('.');
    let parsed = [
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
    ];
    parts.next().is_none().then_some(parsed)
}

pub fn parse_releases(body: &str, current: &str) -> Result<Status, String> {
    let releases: Value = serde_json::from_str(body).map_err(|_| "Invalid release response")?;
    let list = releases.as_array().ok_or("Invalid release response")?;
    let mut best: Option<([u64; 3], String)> = None;
    for release in list {
        if release["draft"] == true {
            continue;
        }
        let Some(tag) = release["tag_name"].as_str() else {
            continue;
        };
        let Some(version) = numeric(tag) else {
            continue;
        };
        if best.as_ref().is_none_or(|(found, _)| version > *found) {
            best = Some((version, tag.to_owned()));
        }
    }
    let Some((latest, tag)) = best else {
        return Err("No published version found".into());
    };
    let installed = numeric(current).ok_or("Invalid installed version")?;
    Ok(if latest > installed {
        Status::Available(tag)
    } else {
        Status::Current
    })
}

pub fn fetch() -> Result<Status, String> {
    let output = Command::new("curl")
        .args([
            "--fail",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            "12",
            "--connect-timeout",
            "5",
            "--max-filesize",
            "1048576",
            "--header",
            "Accept: application/vnd.github+json",
            "--header",
            "User-Agent: insomemo-update-check",
            RELEASES,
        ])
        .output()
        .map_err(|e| format!("Cannot run curl: {e}"))?;
    if !output.status.success() {
        return Err("Network or GitHub request failed".into());
    }
    let body = std::str::from_utf8(&output.stdout).map_err(|_| "Invalid release response")?;
    parse_releases(body, env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn published_prereleases_and_numeric_tags() {
        let releases = r#"[{"tag_name":"v0.2.9","prerelease":true},{"tag_name":"v0.2.10","prerelease":true},{"tag_name":"v0.3.0-beta","prerelease":true},{"tag_name":"v9.0.0","draft":true}]"#;
        assert_eq!(
            parse_releases(releases, "0.2.9").unwrap(),
            Status::Available("v0.2.10".into())
        );
        assert_eq!(parse_releases(releases, "0.2.10").unwrap(), Status::Current);
        assert!(parse_releases("{}", "0.2.9").is_err());
    }
}
