use crate::engine::State;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};

pub struct Store {
    pub path: PathBuf,
    _lock: File,
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(dir.join("daemon.lock"))
            .map_err(|e| e.to_string())?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Another input-switcher instance owns this state directory".into());
        }
        Ok(Self {
            path: dir.join("state.json"),
            _lock: lock,
        })
    }

    pub fn load(&self) -> Result<State, String> {
        let file = match File::open(&self.path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(State::default()),
            Err(e) => return Err(e.to_string()),
        };
        let mut contents = String::new();
        file.take(1_048_577)
            .read_to_string(&mut contents)
            .map_err(|e| e.to_string())?;
        if contents.len() > 1_048_576 {
            return Err("State file exceeds 1 MiB; refusing to overwrite it".into());
        }
        let state: State = serde_json::from_str(&contents).map_err(|e| {
            format!(
                "Invalid state at {} (left untouched): {e}",
                self.path.display()
            )
        })?;
        if state.version != 1 {
            return Err(format!("Unsupported state version {}", state.version));
        }
        Ok(state)
    }

    pub fn save(&self, state: &State) -> Result<(), String> {
        let temporary = self.path.with_extension("json.tmp");
        let data = serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?;
        let result = (|| -> std::io::Result<()> {
            let mut file = OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&temporary)?;
            file.write_all(&data)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            File::open(self.path.parent().unwrap())?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result.map_err(|e| format!("Could not save {}: {e}", self.path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    fn directory() -> PathBuf {
        std::env::temp_dir().join(format!(
            "input-switcher-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }
    #[test]
    fn atomic_private_round_trip_and_single_instance() {
        let dir = directory();
        let store = Store::open(&dir).unwrap();
        assert!(Store::open(&dir).is_err());
        let state = State {
            default_layout: Some("ua".into()),
            ..State::default()
        };
        store.save(&state).unwrap();
        assert_eq!(store.load().unwrap().default_layout.as_deref(), Some("ua"));
        assert_eq!(
            fs::metadata(&store.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(!store.path.with_extension("json.tmp").exists());
        drop(store);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn corrupt_state_is_preserved() {
        let dir = directory();
        let store = Store::open(&dir).unwrap();
        fs::write(&store.path, "broken").unwrap();
        assert!(store.load().is_err());
        assert_eq!(fs::read_to_string(&store.path).unwrap(), "broken");
        drop(store);
        fs::remove_dir_all(dir).unwrap();
    }
}
