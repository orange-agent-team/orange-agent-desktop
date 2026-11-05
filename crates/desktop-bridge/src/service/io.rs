use crate::{api::host::BridgeError, host::failure};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub(super) fn directory(path: &Path) -> Result<PathBuf, BridgeError> {
    if !path.is_absolute() || path.is_symlink() {
        return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(path)
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    let metadata = fs::symlink_metadata(path).map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    if !metadata.is_dir() {
        return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.mode() & 0o077 != 0 {
            return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
        }
    }
    path.canonicalize()
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))
}
pub(super) fn regular(path: &Path, limit: u64, private: bool) -> Result<File, BridgeError> {
    let before = fs::symlink_metadata(path).map_err(|_| failure("MODEL_COMPONENT_UNAVAILABLE"))?;
    if !before.is_file() || before.file_type().is_symlink() || before.len() > limit {
        return Err(failure("MODEL_INTEGRITY"));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        if before.nlink() != 1 || (private && before.mode() & 0o077 != 0) {
            return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
        }
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    let after = file
        .metadata()
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    if !after.is_file() || after.len() > limit {
        return Err(failure("MODEL_INTEGRITY"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || after.nlink() != 1
            || (private && after.mode() & 0o077 != 0)
        {
            return Err(failure("MODEL_INTEGRITY"));
        }
    }
    Ok(file)
}
pub(super) fn read(path: &Path, limit: u64, private: bool) -> Result<Vec<u8>, BridgeError> {
    let mut bytes = Vec::new();
    regular(path, limit, private)?
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    if bytes.len() as u64 > limit {
        return Err(failure("MODEL_INTEGRITY"));
    }
    Ok(bytes)
}
pub(super) fn hash_file(path: &Path, expected: &str, bytes: u64) -> Result<(), BridgeError> {
    if !orange_protocol::valid_digest(expected) || bytes == 0 || bytes > 128 * 1024 * 1024 {
        return Err(failure("MODEL_INTEGRITY"));
    }
    let mut file = regular(path, bytes, false)?;
    if file
        .metadata()
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?
        .len()
        != bytes
    {
        return Err(failure("MODEL_INTEGRITY"));
    }
    let mut hash = Sha256::new();
    let mut chunk = vec![0; 1024 * 1024];
    let mut total = 0_u64;
    loop {
        let count = file
            .read(&mut chunk)
            .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > bytes {
            return Err(failure("MODEL_INTEGRITY"));
        }
        hash.update(&chunk[..count]);
    }
    if total != bytes || hex::encode(hash.finalize()) != expected {
        return Err(failure("MODEL_INTEGRITY"));
    }
    Ok(())
}
pub(super) fn write_json(path: &Path, value: &impl serde::Serialize) -> Result<(), BridgeError> {
    match fs::symlink_metadata(path) {
        Ok(_) => {
            regular(path, 256 * 1024, true)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(failure("MODEL_STORAGE_UNAVAILABLE")),
    }
    let parent = path
        .parent()
        .ok_or_else(|| failure("MODEL_PRIVATE_PATH_REQUIRED"))?;
    let temporary = parent.join(format!(".write-{}", uuid::Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let result = (|| {
        let mut file = options
            .open(&temporary)
            .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
        let bytes = serde_json::to_vec(value).map_err(|_| failure("MODEL_INVALID_STATE"))?;
        if bytes.len() > 256 * 1024 {
            return Err(failure("MODEL_STATE_LIMIT"));
        }
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
        fs::rename(&temporary, path).map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
        #[cfg(unix)]
        File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
pub(super) fn lease(path: &Path) -> Result<File, BridgeError> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    let metadata = file
        .metadata()
        .map_err(|_| failure("MODEL_STORAGE_UNAVAILABLE"))?;
    if !metadata.is_file() || metadata.len() > 1024 {
        return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 || metadata.mode() & 0o077 != 0 {
            return Err(failure("MODEL_PRIVATE_PATH_REQUIRED"));
        }
    }
    file.try_lock().map_err(|_| failure("MODEL_SERVICE_BUSY"))?;
    Ok(file)
}
