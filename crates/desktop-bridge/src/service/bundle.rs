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
fn catalog_model_url(repo: &str, revision: &str, file: &str) -> Result<String, BridgeError> {
    let (publisher, repository) = repo
        .split_once('/')
        .ok_or_else(|| failure("MODEL_CATALOG_INVALID"))?;
    if [publisher, repository, revision, file]
        .iter()
        .any(|segment| {
            segment.is_empty()
                || *segment == "."
                || *segment == ".."
                || segment.contains('/')
                || segment.contains('\\')
        })
    {
        return Err(failure("MODEL_CATALOG_INVALID"));
    }
    if revision.len() != 40 || !revision.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(failure("MODEL_CATALOG_INVALID"));
    }
    let mut url = reqwest::Url::parse("https://huggingface.co/")
        .map_err(|_| failure("MODEL_CATALOG_INVALID"))?;
    url.path_segments_mut()
        .map_err(|_| failure("MODEL_CATALOG_INVALID"))?
        .extend([publisher, repository, "resolve", revision, file]);
    Ok(url.into())
}

fn official_alternate(
    model: &Value,
    digest: &str,
    bytes: u64,
    file: &str,
) -> Result<Option<ArtifactSpec>, BridgeError> {
    let Some(alt) = model
        .get("official_alternates")
        .and_then(|v| v.get("modelscope"))
    else {
        return Ok(None);
    };
    let invalid = || failure("MODEL_CATALOG_INVALID");
    let repo = alt["repository"].as_str().ok_or_else(invalid)?;
    let revision = alt["revision"].as_str().ok_or_else(invalid)?;
    if alt["sha256"].as_str() != Some(digest)
        || alt["bytes"].as_u64() != Some(bytes)
        || model["repository"].as_str() != Some(repo)
        || model["file"].as_str() != Some(file)
        || alt["verified_redirect_host"].as_str() != Some("cdn-lfs-cn-1.modelscope.cn")
        || alt["source"].as_str() != Some(format!("https://modelscope.cn/models/{repo}").as_str())
    {
        return Err(invalid());
    }
    // Apply the same publisher, revision and filename validation as the primary catalogue.
    catalog_model_url(repo, revision, file)?;
    let (publisher, repository) = repo.split_once('/').ok_or_else(invalid)?;
    let mut url = reqwest::Url::parse("https://modelscope.cn/").map_err(|_| invalid())?;
    url.path_segments_mut()
        .map_err(|_| invalid())?
        .extend(["api", "v1", "models", publisher, repository, "repo"]);
    url.query_pairs_mut()
        .append_pair("Revision", revision)
        .append_pair("FilePath", file);
    ArtifactSpec::new(
        url.as_str(),
        digest,
        bytes,
        &["modelscope.cn", "cdn-lfs-cn-1.modelscope.cn"],
        b"GGUF",
    )
    .map(Some)
    .map_err(|_| invalid())
}

pub(super) fn catalog() -> Result<Value, BridgeError> {
    serde_json::from_str(include_str!(env!("ORANGE_DESKTOP_MODEL_CATALOG")))
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
            model_url: catalog_model_url(&text("repository")?, &text("revision")?, &text("file")?)?,
        };
        result.verify_programs()?;
        Ok(result)
    }
    pub fn verify_programs(&self) -> Result<(), BridgeError> {
        io::hash_file(&self.helper, &self.helper_sha, self.helper_bytes)?;
        io::hash_file(&self.backend, &self.backend_sha, self.backend_bytes)
    }
    pub fn alternate_spec(&self) -> Result<Option<ArtifactSpec>, BridgeError> {
        official_alternate(
            &catalog()?["model"],
            &self.model_sha,
            self.model_bytes,
            &self.model_name,
        )
    }
    pub fn spec(&self) -> Result<ArtifactSpec, BridgeError> {
        ArtifactSpec::new(
            &self.model_url,
            &self.model_sha,
            self.model_bytes,
            &["huggingface.co", "us.aws.cdn.hf.co"],
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

#[cfg(test)]
mod alternate_tests {
    use super::*;
    #[test]
    fn exact_alternate_requires_the_same_publisher_digest_length_and_fixed_revision() {
        let model = catalog().expect("pinned catalogue")["model"].clone();
        let digest = model["sha256"].as_str().expect("digest");
        let bytes = model["bytes"].as_u64().expect("size");
        let file = model["file"].as_str().expect("file");
        assert!(
            official_alternate(&model, digest, bytes, file)
                .expect("valid pin")
                .is_some()
        );
        assert!(official_alternate(&model, &"a".repeat(64), bytes, file).is_err());
        assert!(official_alternate(&model, digest, bytes - 1, file).is_err());
        for (field, value) in [
            ("revision", "main"),
            ("repository", "other/repo"),
            ("verified_redirect_host", "example.invalid"),
        ] {
            let mut bad = model.clone();
            bad["official_alternates"]["modelscope"][field] = Value::String(value.into());
            assert!(official_alternate(&bad, digest, bytes, file).is_err());
        }
    }
}
