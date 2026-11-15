//! Compositor IPC only: subscriptions wake GLib's fd source; no polling or shell.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]
use crate::native::Layout;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::PathBuf,
    time::Duration,
};

pub type Event = (String, String, String);
const LIMIT: usize = 4 * 1024 * 1024;

enum Protocol {
    Sway,
    Hyprland,
}
pub struct Backend {
    protocol: Protocol,
    commands: PathBuf,
    stream: UnixStream,
    buffer: Vec<u8>,
    keyboard: Option<String>,
}

fn connection(path: &std::path::Path) -> Result<UnixStream, String> {
    let socket = UnixStream::connect(path).map_err(|e| format!("{}: {e}", path.display()))?;
    socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|e| e.to_string())?;
    socket
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|e| e.to_string())?;
    Ok(socket)
}

fn sway_send(stream: &mut UnixStream, kind: u32, payload: &str) -> Result<(), String> {
    let mut packet = b"i3-ipc".to_vec();
    packet.extend((payload.len() as u32).to_ne_bytes());
    packet.extend(kind.to_ne_bytes());
    packet.extend(payload.as_bytes());
    stream.write_all(&packet).map_err(|e| e.to_string())
}

fn sway_reply(stream: &mut UnixStream) -> Result<Value, String> {
    let mut header = [0; 14];
    stream.read_exact(&mut header).map_err(|e| e.to_string())?;
    let size = frame_size(&header)?;
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes).map_err(|e| e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

fn frame_size(header: &[u8]) -> Result<usize, String> {
    if header.len() < 14 || &header[..6] != b"i3-ipc" {
        return Err("Invalid Sway IPC header".into());
    }
    let size = u32::from_ne_bytes(header[6..10].try_into().unwrap()) as usize;
    if size > LIMIT {
        return Err("Sway IPC message exceeds 4 MiB".into());
    }
    Ok(size)
}

fn focused(node: &Value) -> Option<&Value> {
    if node["focused"].as_bool() == Some(true) {
        return Some(node);
    }
    for field in ["nodes", "floating_nodes"] {
        if let Some(children) = node[field].as_array() {
            for child in children {
                if let Some(found) = focused(child) {
                    return Some(found);
                }
            }
        }
    }
    None
}
fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or("").into()
}
fn layout(name: &str) -> Layout {
    let lower = name.to_lowercase();
    let code = if lower.contains("ukrain") {
        "UA".into()
    } else if lower.contains("english") {
        "EN".into()
    } else {
        name.chars()
            .filter(|c| c.is_alphabetic())
            .take(2)
            .collect::<String>()
            .to_uppercase()
    };
    Layout {
        id: format!("xkb:{name}"),
        name: name.into(),
        code,
    }
}

impl Backend {
    pub fn detect(keyboard: Option<String>) -> Result<Option<Self>, String> {
        if let Some(path) = std::env::var_os("SWAYSOCK") {
            let commands = PathBuf::from(path);
            let mut stream = connection(&commands)?;
            sway_send(
                &mut stream,
                2,
                r#"["window","input","workspace","shutdown"]"#,
            )?;
            if sway_reply(&mut stream)?["success"] != true {
                return Err("Sway refused event subscription".into());
            }
            stream.set_nonblocking(true).map_err(|e| e.to_string())?;
            return Ok(Some(Self {
                protocol: Protocol::Sway,
                commands,
                stream,
                buffer: vec![],
                keyboard,
            }));
        }
        if let Some(signature) = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") {
            let runtime =
                std::env::var_os("XDG_RUNTIME_DIR").ok_or("Hyprland requires XDG_RUNTIME_DIR")?;
            let root = PathBuf::from(runtime).join("hypr").join(signature);
            let stream = connection(&root.join(".socket2.sock"))?;
            stream.set_nonblocking(true).map_err(|e| e.to_string())?;
            return Ok(Some(Self {
                protocol: Protocol::Hyprland,
                commands: root.join(".socket.sock"),
                stream,
                buffer: vec![],
                keyboard,
            }));
        }
        if std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").as_deref() == Ok("wayland")
        {
            return Err("This Wayland compositor is not supported. Use Sway or Hyprland. GNOME/KDE require a compositor extension; XWayland cannot observe native Wayland windows.".into());
        }
        Ok(None)
    }

    pub fn fd(&self) -> i32 {
        self.stream.as_raw_fd()
    }
    fn request(&self, kind: u32, payload: &str) -> Result<Value, String> {
        let mut stream = connection(&self.commands)?;
        match self.protocol {
            Protocol::Sway => {
                sway_send(&mut stream, kind, payload)?;
                sway_reply(&mut stream)
            }
            Protocol::Hyprland => {
                stream
                    .write_all(payload.as_bytes())
                    .map_err(|e| e.to_string())?;
                let mut bytes = Vec::new();
                stream
                    .take((LIMIT + 1) as u64)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                if bytes.len() > LIMIT {
                    return Err("Hyprland IPC message exceeds 4 MiB".into());
                }
                if bytes == b"ok" {
                    return Ok(json!({"success": true}));
                }
                serde_json::from_slice(&bytes).map_err(|e| format!("Invalid Hyprland reply: {e}"))
            }
        }
    }

    fn keyboard(&self) -> Result<Value, String> {
        let value = match self.protocol {
            Protocol::Sway => self.request(100, "")?,
            Protocol::Hyprland => self.request(0, "j/devices")?["keyboards"].clone(),
        };
        let all = value
            .as_array()
            .ok_or("Compositor returned no keyboard list")?;
        let keyboards: Vec<_> = all
            .iter()
            .filter(|v| matches!(self.protocol, Protocol::Hyprland) || v["type"] == "keyboard")
            .collect();
        let key = match self.protocol {
            Protocol::Sway => "identifier",
            Protocol::Hyprland => "name",
        };
        let selected = if let Some(name) = &self.keyboard {
            keyboards.iter().find(|v| v[key].as_str() == Some(name))
        } else {
            keyboards
                .iter()
                .find(|v| v["main"] == true)
                .or_else(|| keyboards.first())
        };
        selected
            .map(|v| (*v).clone())
            .ok_or_else(|| "No matching keyboard; check the keyboard config field".into())
    }

    fn keyboard_layouts(&self, keyboard: &Value) -> Result<Vec<Layout>, String> {
        match self.protocol {
            Protocol::Sway => keyboard["xkb_layout_names"]
                .as_array()
                .ok_or_else(|| "Sway did not expose keyboard layouts".into())
                .map(|names| names.iter().filter_map(Value::as_str).map(layout).collect()),
            Protocol::Hyprland => hypr_layouts(keyboard),
        }
    }

    pub fn layouts(&mut self) -> Result<Vec<Layout>, String> {
        self.keyboard_layouts(&self.keyboard()?)
    }

    pub fn select(&mut self, id: &str) -> Result<(), String> {
        let keyboard = self.keyboard()?;
        let layouts = self.keyboard_layouts(&keyboard)?;
        let index = layouts
            .iter()
            .position(|l| l.id == id)
            .ok_or("Saved layout is no longer configured")?;
        match self.protocol {
            Protocol::Sway => {
                let name =
                    serde_json::to_string(&keyboard["identifier"]).map_err(|e| e.to_string())?;
                let response =
                    self.request(0, &format!("input {name} xkb_switch_layout {index}"))?;
                if !response
                    .as_array()
                    .is_some_and(|r| !r.is_empty() && r.iter().all(|v| v["success"] == true))
                {
                    return Err(format!("Sway rejected layout selection: {response}"));
                }
            }
            Protocol::Hyprland => {
                let name = text(&keyboard, "name");
                if !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_.:".contains(c))
                {
                    return Err("Unsupported keyboard name in Hyprland IPC".into());
                }
                if self.request(0, &format!("/switchxkblayout {name} {index}"))?["success"] != true
                {
                    return Err("Hyprland rejected layout selection".into());
                }
            }
        }
        Ok(())
    }

    fn context(&self) -> Result<Event, String> {
        let (app, title) = match self.protocol {
            Protocol::Sway => {
                let tree = self.request(4, "")?;
                let node = focused(&tree).cloned().unwrap_or(Value::Null);
                let app = node["app_id"]
                    .as_str()
                    .or_else(|| node["window_properties"]["class"].as_str())
                    .unwrap_or("")
                    .to_owned();
                (app, text(&node, "name"))
            }
            Protocol::Hyprland => {
                let window = self.request(0, "j/activewindow")?;
                (text(&window, "class"), text(&window, "title"))
            }
        };
        Ok(("context".into(), app, title))
    }

    pub fn current_layout(&self) -> Result<Event, String> {
        let keyboard = self.keyboard()?;
        let name = match self.protocol {
            Protocol::Sway => text(&keyboard, "xkb_active_layout_name"),
            Protocol::Hyprland => text(&keyboard, "active_keymap"),
        };
        if name.is_empty() {
            return Err("Compositor did not expose the active keyboard layout".into());
        }
        Ok(("layout".into(), layout(&name).id, String::new()))
    }

    pub fn snapshot(&mut self) -> Result<Vec<Event>, String> {
        Ok(vec![
            reported(self.current_layout()),
            reported(self.context()),
        ])
    }

    pub fn events(&mut self) -> Result<Vec<Event>, String> {
        let mut chunk = [0; 8192];
        loop {
            match self.stream.read(&mut chunk) {
                Ok(0) => return Err("Compositor event connection closed".into()),
                Ok(n) => self.buffer.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e.to_string()),
            }
            if self.buffer.len() > LIMIT {
                return Err("Compositor event buffer exceeds 4 MiB".into());
            }
        }
        let mut focus = false;
        let mut input = false;
        let mut layouts = false;
        match self.protocol {
            Protocol::Sway => {
                while self.buffer.len() >= 14 {
                    let size = frame_size(&self.buffer[..14])?;
                    if self.buffer.len() < 14 + size {
                        break;
                    }
                    let kind =
                        u32::from_ne_bytes(self.buffer[10..14].try_into().unwrap()) & 0x7fff_ffff;
                    let data: Value = serde_json::from_slice(&self.buffer[14..14 + size])
                        .map_err(|e| e.to_string())?;
                    match kind {
                        0 | 3 => focus = true,
                        21 => {
                            input = true;
                            layouts |= data["change"] != "xkb_layout";
                        }
                        6 => return Err("Sway is shutting down".into()),
                        _ => (),
                    }
                    self.buffer.drain(..14 + size);
                }
            }
            Protocol::Hyprland => {
                while let Some(end) = self.buffer.iter().position(|c| *c == b'\n') {
                    let line = String::from_utf8_lossy(&self.buffer[..end]);
                    let kind = line.split_once(">>").map(|(kind, _)| kind).unwrap_or("");
                    match kind {
                        "activewindow" | "activewindowv2" | "windowtitle" | "windowtitlev2"
                        | "workspace" => focus = true,
                        "activelayout" => input = true,
                        "configreloaded" => {
                            input = true;
                            layouts = true;
                        }
                        _ => (),
                    }
                    self.buffer.drain(..=end);
                }
            }
        }
        let mut events = Vec::new();
        if layouts {
            events.push(("layouts".into(), String::new(), String::new()));
        }
        // Query current state instead of replaying stale notification payloads.
        if focus {
            // A slow command socket is not fatal; only the event stream is.
            events.push(reported(self.context()));
        }
        if input {
            // Resolve after the focus event has actually restored its layout.
            events.push(("refresh-layout".into(), String::new(), String::new()));
        }
        Ok(events)
    }
}

/// Turns a failed compositor query into a tray error instead of a fatal one.
fn reported(result: Result<Event, String>) -> Event {
    result.unwrap_or_else(|e| ("error".into(), e, String::new()))
}

#[cfg(target_os = "linux")]
fn hypr_layouts(keyboard: &Value) -> Result<Vec<Layout>, String> {
    use crate::native::cstring;
    use std::ffi::{CStr, c_char};
    unsafe extern "C" {
        fn native_xkb_names(layouts: *const c_char, variants: *const c_char) -> *mut c_char;
        fn native_free(value: *mut c_char);
    }
    unsafe {
        let ptr = native_xkb_names(
            cstring(&text(keyboard, "layout")).as_ptr(),
            cstring(&text(keyboard, "variant")).as_ptr(),
        );
        if ptr.is_null() {
            return Err("Cannot compile Hyprland XKB layout names".into());
        }
        let names: Result<Vec<String>, _> = serde_json::from_slice(CStr::from_ptr(ptr).to_bytes());
        native_free(ptr);
        Ok(names
            .map_err(|e| e.to_string())?
            .iter()
            .map(|s| layout(s))
            .collect())
    }
}
#[cfg(not(target_os = "linux"))]
fn hypr_layouts(_: &Value) -> Result<Vec<Layout>, String> {
    Err("Only available on Linux".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn focused_window_in_floating_tree() {
        let tree = json!({"nodes": [{"focused":false}], "floating_nodes": [{"nodes": [{"focused":true,"app_id":"terminal"}]}]});
        assert_eq!(focused(&tree).unwrap()["app_id"], "terminal");
    }
    #[test]
    fn ipc_frames_are_bounded_and_native_endian() {
        let mut packet = b"i3-ipc".to_vec();
        packet.extend(42_u32.to_ne_bytes());
        packet.extend(0_u32.to_ne_bytes());
        assert_eq!(frame_size(&packet).unwrap(), 42);
        packet[6..10].copy_from_slice(&u32::MAX.to_ne_bytes());
        assert!(frame_size(&packet).is_err());
        assert!(frame_size(b"garbage").is_err());
    }
    #[test]
    fn stable_layout_ids_survive_reordering() {
        assert_eq!(layout("Ukrainian").id, "xkb:Ukrainian");
        assert_eq!(layout("Ukrainian").code, "UA");
        assert_eq!(layout("English (US)").code, "EN");
    }

    #[test]
    fn fragmented_sway_events_wait_for_full_frame_and_defer_layout_read() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let mut backend = Backend {
            protocol: Protocol::Sway,
            commands: PathBuf::new(),
            stream: reader,
            buffer: Vec::new(),
            keyboard: None,
        };
        let payload = r#"{"change":"xkb_layout"}"#;
        let mut packet = b"i3-ipc".to_vec();
        packet.extend((payload.len() as u32).to_ne_bytes());
        packet.extend((0x8000_0000_u32 | 21).to_ne_bytes());
        packet.extend(payload.as_bytes());
        writer.write_all(&packet[..17]).unwrap();
        assert!(backend.events().unwrap().is_empty());
        writer.write_all(&packet[17..]).unwrap();
        let events = backend.events().unwrap();
        assert_eq!(
            events,
            vec![("refresh-layout".into(), String::new(), String::new())]
        );
        assert!(backend.buffer.is_empty());
    }

    #[test]
    fn hyprland_subscription_buffers_partial_lines() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let mut backend = Backend {
            protocol: Protocol::Hyprland,
            commands: PathBuf::new(),
            stream: reader,
            buffer: Vec::new(),
            keyboard: None,
        };
        writer.write_all(b"activelayout>>keyboard,Ukrain").unwrap();
        assert!(backend.events().unwrap().is_empty());
        writer.write_all(b"ian\n").unwrap();
        assert_eq!(backend.events().unwrap()[0].0, "refresh-layout");
    }

    #[test]
    fn failed_context_query_is_reported_not_fatal() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let mut backend = Backend {
            protocol: Protocol::Hyprland,
            commands: PathBuf::from("/nonexistent/insomemo.sock"),
            stream: reader,
            buffer: Vec::new(),
            keyboard: None,
        };
        writer.write_all(b"activewindow>>kitty,shell\n").unwrap();
        let events = backend.events().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, "error");
    }
}
