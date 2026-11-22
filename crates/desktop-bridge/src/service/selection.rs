use super::{Bundle, Settings, io};
use crate::{api::host::BridgeError, host::failure};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) enum Profile {
    #[default]
    #[serde(rename = "local-small")]
    Small,
    #[serde(rename = "local-7b")]
    SevenB,
}
impl Profile {
    pub fn id(self) -> &'static str {
        match self {
            Self::Small => "local-small",
            Self::SevenB => "local-7b",
        }
    }
    pub fn parse(id: &str) -> Result<Self, BridgeError> {
        match id {
            "local-small" => Ok(Self::Small),
            "local-7b" => Ok(Self::SevenB),
            _ => Err(failure("MODEL_PROFILE_UNKNOWN")),
        }
    }
    pub fn alias(self) -> &'static str {
        match self {
            Self::Small => "orange-local-qwen-v1",
            Self::SevenB => "orange-local-qwen7b-v1",
        }
    }
    pub fn quota(self) -> u64 {
        match self {
            Self::Small => 2 * 1024 * 1024 * 1024,
            Self::SevenB => 5 * 1024 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Selection {
    pub profile: Profile,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    threads: Option<u16>,
}
impl Selection {
    pub fn threads(self) -> u16 {
        match self.profile {
            Profile::Small => 2,
            Profile::SevenB => self.threads.unwrap_or(4),
        }
    }
    pub fn alias(self) -> String {
        match (self.profile, self.threads) {
            (Profile::SevenB, Some(n)) => format!("orange-local-qwen7b-t{n}-v1"),
            _ => self.profile.alias().into(),
        }
    }
    pub fn load(root: &Path) -> Result<Self, BridgeError> {
        let p = root.join("model-selection.json");
        match std::fs::symlink_metadata(&p) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(_) => Err(failure("MODEL_STORAGE_UNAVAILABLE")),
            Ok(_) => {
                let value: Self = serde_json::from_slice(&io::read(&p, 4096, true)?)
                    .map_err(|_| failure("MODEL_RECOVERY_REQUIRED"))?;
                if (value.revision == 0 && value.profile != Profile::Small)
                    || value
                        .threads
                        .is_some_and(|n| value.profile != Profile::SevenB || !(1..=8).contains(&n))
                {
                    return Err(failure("MODEL_RECOVERY_REQUIRED"));
                }
                Ok(value)
            }
        }
    }
    pub fn save(self, root: &Path) -> Result<(), BridgeError> {
        io::write_json(&root.join("model-selection.json"), &self)
    }
    pub fn require(self, expected: Option<&str>) -> Result<(), BridgeError> {
        if expected.unwrap_or("0") != self.revision.to_string() {
            return Err(failure("MODEL_SELECTION_CHANGED"));
        }
        Ok(())
    }
    pub fn next(self, id: &str, expected: &str) -> Result<Self, BridgeError> {
        let target = Profile::parse(id)?;
        if target == self.profile
            && self
                .revision
                .checked_sub(1)
                .is_some_and(|old| old.to_string() == expected)
        {
            return Ok(self);
        }
        self.require(Some(expected))?;
        if target == self.profile {
            return Ok(self);
        }
        Ok(Self {
            profile: target,
            threads: if target == Profile::SevenB {
                let available = std::thread::available_parallelism()
                    .map_err(|_| failure("MODEL_CPU_CAPACITY_UNKNOWN"))?;
                Some(available.get().min(8) as u16)
            } else {
                None
            },
            revision: self
                .revision
                .checked_add(1)
                .ok_or_else(|| failure("MODEL_RECOVERY_REQUIRED"))?,
        })
    }
}

impl Settings {
    pub(super) fn confirms_execution(&self, threads: Option<u16>, digest: Option<&str>) -> bool {
        if self.selection.profile == Profile::Small {
            return threads.is_none() && digest.is_none();
        }
        #[cfg(unix)]
        {
            let profile = orange_model_runtime::supervisor::CpuProfile {
                socket_directory: Some(self.ipc.clone()),
                executable: self.bundle.backend.clone(),
                executable_sha256: self.bundle.backend_sha.clone(),
                model: self.cache.join(format!("{}.gguf", self.bundle.model_sha)),
                model_sha256: self.bundle.model_sha.clone(),
                model_bytes: self.bundle.model_bytes,
                model_version: self.selection.alias(),
                context_tokens: 8192,
                startup_timeout: std::time::Duration::from_secs(self.startup_seconds),
            };
            threads == Some(self.selection.threads())
                && profile
                    .execution_digest_with_threads(self.selection.threads())
                    .is_ok_and(|expected| Some(expected.as_str()) == digest)
        }
        #[cfg(not(unix))]
        {
            false
        }
    }
    pub fn base_ipc(&self) -> &Path {
        if self.selection.profile == Profile::Small {
            &self.ipc
        } else {
            self.ipc
                .parent()
                .expect("7B socket uses a private child directory")
        }
    }
    pub fn for_selection(
        host_root: &Path,
        mut bundle: Bundle,
        base_ipc: &Path,
        selection: Selection,
    ) -> Result<Self, BridgeError> {
        bundle.select_profile(selection.profile)?;
        let (name, cache, ipc): (&str, &str, PathBuf) = match selection.profile {
            Profile::Small => ("m", "models", base_ipc.to_owned()),
            Profile::SevenB => ("m7", "models7", base_ipc.join("b")),
        };
        let ipc = io::directory(&ipc)?;
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            if ipc.join("engine.sock").as_os_str().as_bytes().len() > 100 {
                return Err(failure("MODEL_IPC_PATH_TOO_LONG"));
            }
        }
        Ok(Self {
            bundle,
            root: io::directory(&host_root.join(name))?,
            cache: io::directory(&host_root.join(cache))?,
            ipc,
            selection,
            startup_seconds: 120,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_replay_cannot_restore_authority_after_switching_back() {
        let a = Selection::default();
        let b = a.next("local-7b", "0").expect("choose larger weights");
        assert!(b.require(None).is_err());
        assert_eq!(b.next("local-7b", "0").expect("original reply").revision, 1);
        let c = b.next("local-small", "1").expect("switch back");
        assert!(c.next("local-7b", "0").is_err());
        assert!(c.require(Some("1")).is_err());
        assert!(c.require(None).is_err());
        assert!(c.require(Some("2")).is_ok());
        assert!(c.next("unregistered", "2").is_err());
    }
}
