use super::io;
use crate::{api::host::BridgeError, host::failure};
use orange_model_runtime::cache::ArtifactSpec;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(crate) struct Bundle {
    pub contents: PathBuf,
    pub helper: PathBuf,
    pub backend: PathBuf,
    pub helper_sha: String,
    pub helper_bytes: u64,
    pub backend_sha: String,
    pub backend_bytes: u64,
    pub model_sha: String,
    pub model_bytes: u64,
    pub model_name: String,
    pub model_url: String,
}
pub(super) fn catalog() -> Result<Value, BridgeError> {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../vendor/runtime-53ed515/config/local-model.lock.json"
    )))
    .map_err(|_| failure("MODEL_CATALOG_INVALID"))
}
fn version(value: &str) -> Result<[u32; 3], BridgeError> {
    let parts = value.split('.').collect::<Vec<_>>();
    if parts.is_empty() || parts.len() > 3 {
        return Err(failure("MODEL_PLATFORM_UNAVAILABLE"));
    }
    let mut result = [0; 3];
    for (index, part) in parts.iter().enumerate() {
        result[index] = part
            .parse()
            .map_err(|_| failure("MODEL_PLATFORM_UNAVAILABLE"))?;
    }
    Ok(result)
}
impl Bundle {
    pub fn open(
        contents: &Path,
        os_version: &str,
        expected_runtime: &str,
    ) -> Result<Self, BridgeError> {
        Self::bound(
            contents,
            os_version,
            expected_runtime,
            option_env!("ORANGE_MODEL_BUNDLE_SHA256").unwrap_or("not-packaged"),
        )
    }
    fn bound(
        contents: &Path,
        os_version: &str,
        expected_runtime: &str,
        expected_manifest: &str,
    ) -> Result<Self, BridgeError> {
        if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            return Err(failure("MODEL_PLATFORM_UNAVAILABLE"));
        }
        if !orange_protocol::valid_digest(expected_manifest) {
            return Err(failure("MODEL_SERVICE_NOT_PACKAGED"));
        }
        if !contents.is_absolute() || contents.is_symlink() {
            return Err(failure("MODEL_INTEGRITY"));
        }
        let contents = contents
            .canonicalize()
            .map_err(|_| failure("MODEL_SERVICE_NOT_PACKAGED"))?;
        for folder in [
            contents.join("Helpers"),
            contents.join("Resources"),
            contents.join("Resources/OrangeModelService"),
        ] {
            if folder.is_symlink() || !folder.is_dir() {
                return Err(failure("MODEL_INTEGRITY"));
            }
        }
        let bytes = io::read(
            &contents.join("Resources/OrangeModelService/manifest.json"),
            256 * 1024,
            false,
        )?;
        if hex::encode(Sha256::digest(&bytes)) != expected_manifest {
            return Err(failure("MODEL_INTEGRITY"));
        }
        let manifest: Value =
            serde_json::from_slice(&bytes).map_err(|_| failure("MODEL_INTEGRITY"))?;
        let approved = catalog()?;
        if manifest["schema"] != "orange-model-service-bundle-v1"
            || manifest["platform"] != "macos-arm64"
            || manifest["cpu_only"] != true
            || manifest["development_only"] != true
            || manifest["runtime_commit"] != expected_runtime
            || manifest["backend_commit"] != approved["backend"]["commit"]
            || manifest["model"] != approved["model"]
        {
            return Err(failure("MODEL_INTEGRITY"));
        }
        if version(os_version)?
            < version(
                manifest["minimum_macos"]
                    .as_str()
                    .ok_or_else(|| failure("MODEL_INTEGRITY"))?,
            )?
        {
            return Err(failure("MODEL_PLATFORM_UNAVAILABLE"));
        }
        let field = |name: &str| -> Result<(String, u64), BridgeError> {
            let item = &manifest["files"][name];
            if item["executable"] != true {
                return Err(failure("MODEL_INTEGRITY"));
            }
            Ok((
                item["sha256"]
                    .as_str()
                    .ok_or_else(|| failure("MODEL_INTEGRITY"))?
                    .into(),
                item["bytes"]
                    .as_u64()
                    .ok_or_else(|| failure("MODEL_INTEGRITY"))?,
            ))
        };
        let (helper_sha, helper_bytes) = field("orange-model-host")?;
        let (backend_sha, backend_bytes) = field("llama-server")?;
        let model = &approved["model"];
        let text = |key: &str| {
            model[key]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| failure("MODEL_CATALOG_INVALID"))
        };
        let result = Self {
            helper: contents.join("Helpers/orange-model-host"),
            backend: contents.join("Helpers/llama-server"),
            contents,
            helper_sha,
            helper_bytes,
            backend_sha,
            backend_bytes,
            model_sha: text("sha256")?,
            model_bytes: model["bytes"]
                .as_u64()
                .ok_or_else(|| failure("MODEL_CATALOG_INVALID"))?,
            model_name: text("file")?,
            model_url: format!(
                "https://huggingface.co/{}/resolve/{}/{}",
                text("repository")?,
                text("revision")?,
                text("file")?
            ),
        };
        result.verify_programs()?;
        Ok(result)
    }
    pub fn verify_programs(&self) -> Result<(), BridgeError> {
        io::hash_file(&self.helper, &self.helper_sha, self.helper_bytes)?;
        io::hash_file(&self.backend, &self.backend_sha, self.backend_bytes)
    }
    pub fn spec(&self) -> Result<ArtifactSpec, BridgeError> {
        ArtifactSpec::new(
            &self.model_url,
            &self.model_sha,
            self.model_bytes,
            &["huggingface.co"],
            b"GGUF",
        )
        .map_err(|_| failure("MODEL_CATALOG_INVALID"))
    }
}
#[cfg(all(test, target_os = "macos", target_arch = "aarch64"))]
mod tests {
    use super::*;
    #[test]
    fn compiled_fingerprint_rejects_self_rehashed_runtime_bundle_and_wrong_catalog() {
        let temp = tempfile::tempdir().expect("owned fixture");
        let contents = temp.path().join("Fixture.app/Contents");
        let resources = contents.join("Resources/OrangeModelService");
        std::fs::create_dir_all(&resources).expect("resources");
        std::fs::create_dir_all(contents.join("Helpers")).expect("helpers");
        let program = b"non-executed-integrity-fixture";
        for name in ["orange-model-host", "llama-server"] {
            std::fs::write(contents.join("Helpers").join(name), program).expect("fixture bytes");
        }
        let approved = catalog().expect("fixed catalog");
        let item = serde_json::json!({"sha256":hex::encode(Sha256::digest(program)),"bytes":program.len(),"executable":true});
        let mut value = serde_json::json!({"schema":"orange-model-service-bundle-v1","platform":"macos-arm64","cpu_only":true,"development_only":true,"runtime_commit":"fixture-runtime","backend_commit":approved["backend"]["commit"],"model":approved["model"],"minimum_macos":"27.2","files":{"orange-model-host":item,"llama-server":item}});
        let path = resources.join("manifest.json");
        let original = serde_json::to_vec(&value).expect("manifest");
        std::fs::write(&path, &original).expect("manifest file");
        let pinned = hex::encode(Sha256::digest(&original));
        Bundle::bound(&contents, "27.2.0", "fixture-runtime", &pinned)
            .expect("hash/inventory-only fixture, never executed");
        assert!(Bundle::bound(&contents, "12.0", "fixture-runtime", &pinned).is_err());
        let altered = b"different non-executed program";
        std::fs::write(contents.join("Helpers/llama-server"), altered).expect("tamper");
        value["files"]["llama-server"]["sha256"] =
            serde_json::json!(hex::encode(Sha256::digest(altered)));
        value["files"]["llama-server"]["bytes"] = serde_json::json!(altered.len());
        std::fs::write(
            &path,
            serde_json::to_vec(&value).expect("tampered inventory"),
        )
        .expect("self rehash");
        assert_eq!(
            Bundle::bound(&contents, "27.2", "fixture-runtime", &pinned)
                .err()
                .expect("compile-time pin must reject changed inventory")
                .code,
            "MODEL_INTEGRITY"
        );
        value["model"]["sha256"] = serde_json::json!("0".repeat(64));
        let changed = serde_json::to_vec(&value).expect("wrong catalog");
        std::fs::write(&path, &changed).expect("fixture manifest");
        assert_eq!(
            Bundle::bound(
                &contents,
                "27.2",
                "fixture-runtime",
                &hex::encode(Sha256::digest(changed))
            )
            .err()
            .expect("catalog is also independently pinned")
            .code,
            "MODEL_INTEGRITY"
        );
    }
}
