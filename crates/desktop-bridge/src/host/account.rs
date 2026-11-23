use super::failure;
use crate::api::{account::*, host::BridgeError};
use orange_protocol::{
    account::{PersonalBudgetList, WalletView},
    valid_id,
};
use reqwest::{Certificate, Client, Url, header};
use serde::{Deserialize, de::DeserializeOwned};
use std::time::Duration;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    user_api_origin: String,
    allow_local_development_certificate: bool,
}

fn profile() -> Result<(Url, PersonalApiEndpoint), BridgeError> {
    parse_profile(include_str!(
        "../../../../config/personal-account-origin.json"
    ))
}
fn parse_profile(document: &str) -> Result<(Url, PersonalApiEndpoint), BridgeError> {
    let p: Profile =
        serde_json::from_str(document).map_err(|_| failure("ACCOUNT_DEPLOYMENT_INVALID"))?;
    let url = Url::parse(&p.user_api_origin).map_err(|_| failure("ACCOUNT_DEPLOYMENT_INVALID"))?;
    if url.scheme() != "https"
        || url.host().is_none()
        || p.user_api_origin != url.origin().ascii_serialization()
        || (p.allow_local_development_certificate && url.host_str() != Some("127.0.0.1"))
    {
        return Err(failure("ACCOUNT_DEPLOYMENT_INVALID"));
    }
    Ok((
        url,
        PersonalApiEndpoint {
            origin: p.user_api_origin,
            allow_local_development_certificate: p.allow_local_development_certificate,
        },
    ))
}
pub(crate) fn endpoint(handle: &str) -> Result<PersonalApiEndpoint, BridgeError> {
    crate::actor::inspect(handle)?;
    Ok(profile()?.1)
}

fn authorization(credential: &str) -> Result<header::HeaderValue, BridgeError> {
    let (id, secret) = credential
        .strip_prefix("oa1.")
        .and_then(|v| v.split_once('.'))
        .ok_or_else(|| failure("ACCOUNT_KEY_INVALID"))?;
    if credential.len() != 105
        || !Uuid::parse_str(id).is_ok_and(|v| {
            v.get_variant() == uuid::Variant::RFC4122
                && v.get_version_num() == 4
                && v.to_string() == id
        })
        || secret.len() != 64
        || !secret
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(failure("ACCOUNT_KEY_INVALID"));
    }
    let mut header = header::HeaderValue::from_str(&format!("Bearer {credential}"))
        .map_err(|_| failure("ACCOUNT_KEY_INVALID"))?;
    header.set_sensitive(true);
    Ok(header)
}

fn transport(pairing: Option<&str>, endpoint: &PersonalApiEndpoint) -> Result<Client, BridgeError> {
    let mut builder = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .https_only(true)
        .connect_timeout(Duration::from_secs(4))
        .timeout(Duration::from_secs(12));
    if endpoint.allow_local_development_certificate {
        builder = builder.no_proxy();
    }
    if let Some(pem) = pairing {
        if !endpoint.allow_local_development_certificate
            || pem.len() > 16384
            || !pem.trim().starts_with("-----BEGIN CERTIFICATE-----")
            || !pem.trim().ends_with("-----END CERTIFICATE-----")
            || pem.matches("-----BEGIN").count() != 1
            || pem.matches("-----END").count() != 1
        {
            return Err(failure("ACCOUNT_CERTIFICATE_INVALID"));
        }
        let cert = Certificate::from_pem(pem.as_bytes())
            .map_err(|_| failure("ACCOUNT_CERTIFICATE_INVALID"))?;
        builder = builder
            .tls_built_in_root_certs(false)
            .add_root_certificate(cert);
    }
    builder
        .build()
        .map_err(|_| failure("ACCOUNT_TLS_UNAVAILABLE"))
}

async fn get<T: DeserializeOwned>(
    handle: &str,
    credential: &str,
    pem: Option<&str>,
    resource: &str,
    page: Option<(&str, u16)>,
) -> Result<T, BridgeError> {
    crate::actor::inspect(handle)?;
    static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
    let _permit = READS
        .try_acquire()
        .map_err(|_| failure("ACCOUNT_READ_BUSY"))?;
    let (mut url, endpoint) = profile()?;
    let access = authorization(credential)?;
    url.set_path(resource);
    if let Some((after, limit)) = page {
        if !(1..=100).contains(&limit) || (!after.is_empty() && !valid_id(after)) {
            return Err(failure("ACCOUNT_CURSOR_INVALID"));
        }
        let mut q = url.query_pairs_mut();
        q.append_pair("limit", &limit.to_string());
        if !after.is_empty() {
            q.append_pair("after", after);
        }
    }
    let mut response = transport(pem, &endpoint)?
        .get(url)
        .header(header::AUTHORIZATION, access)
        .header(header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|_| failure("ACCOUNT_CONNECTION_FAILED"))?;
    if response.status() != reqwest::StatusCode::OK {
        return Err(failure(match response.status().as_u16() {
            401 => "ACCOUNT_KEY_INACTIVE",
            403 => "ACCOUNT_SCOPE_DENIED",
            429 => "ACCOUNT_RATE_LIMITED",
            _ => "ACCOUNT_READ_UNCONFIRMED",
        }));
    }
    const MAX: usize = 65536;
    if response.content_length().is_some_and(|n| n > MAX as u64)
        || response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(';').next())
            != Some("application/json")
    {
        return Err(failure("ACCOUNT_RESPONSE_INVALID"));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| failure("ACCOUNT_CONNECTION_FAILED"))?
    {
        if chunk.len() > MAX - bytes.len() {
            return Err(failure("ACCOUNT_RESPONSE_INVALID"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| failure("ACCOUNT_RESPONSE_INVALID"))?;
    crate::actor::inspect(handle)?;
    Ok(value)
}
pub(crate) async fn wallet(
    handle: &str,
    credential: &str,
    pem: Option<&str>,
) -> Result<RemoteWalletView, BridgeError> {
    let v: WalletView = get(
        handle,
        credential,
        pem,
        "/api/v1/automation/account/wallet",
        None,
    )
    .await?;
    if !valid_id(&v.user_id) || !valid_id(&v.owner_id) {
        return Err(failure("ACCOUNT_RESPONSE_INVALID"));
    }
    Ok(RemoteWalletView {
        user_id: v.user_id,
        owner_id: v.owner_id,
        gift: v.gift.into(),
        earned: v.earned.into(),
        purchased: v.purchased.into(),
        reserved_gift: v.reserved_gift.into(),
        reserved_earned: v.reserved_earned.into(),
        reserved_purchased: v.reserved_purchased.into(),
        pending_earned: v.pending_earned.into(),
    })
}
pub(crate) async fn budgets(
    handle: &str,
    credential: &str,
    pem: Option<&str>,
    after: Option<&str>,
    limit: u16,
) -> Result<RemoteBudgetPage, BridgeError> {
    if after.is_some_and(|v| !valid_id(v)) {
        return Err(failure("ACCOUNT_CURSOR_INVALID"));
    }
    let v: PersonalBudgetList = get(
        handle,
        credential,
        pem,
        "/api/v1/automation/account/budgets",
        Some((after.unwrap_or(""), limit)),
    )
    .await?;
    if !valid_id(&v.user_id)
        || !valid_id(&v.owner_id)
        || v.data.len() > usize::from(limit)
        || v.next_cursor
            .as_ref()
            .is_some_and(|s| v.data.last().map(|r| &r.root_budget_id) != Some(s))
    {
        return Err(failure("ACCOUNT_RESPONSE_INVALID"));
    }
    let mut data = Vec::new();
    let mut last = after.unwrap_or("").to_owned();
    for row in v.data {
        if !valid_id(&row.scope_id)
            || !valid_id(&row.root_budget_id)
            || row.root_budget_id <= last
            || !matches!(row.status.as_str(), "active" | "closing" | "closed")
            || i128::from(row.spent.0.units()) + i128::from(row.reserved.0.units())
                > i128::from(row.limit.0.units())
        {
            return Err(failure("ACCOUNT_RESPONSE_INVALID"));
        }
        last.clone_from(&row.root_budget_id);
        data.push(RemoteBudgetView {
            root_budget_id: row.root_budget_id,
            scope_id: row.scope_id,
            limit: row.limit.into(),
            spent: row.spent.into(),
            reserved: row.reserved.into(),
            status: row.status,
        });
    }
    Ok(RemoteBudgetPage {
        user_id: v.user_id,
        owner_id: v.owner_id,
        data,
        next_cursor: v.next_cursor,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deployment_origin_and_custom_roots_remain_operator_scoped() {
        for origin in [
            "http://127.0.0.1:43122",
            "https://user@server.test",
            "https://server.test/prefix",
            "https://server.test?next=x",
            "https://server.test/#fragment",
        ] {
            let p = serde_json::json!({"user_api_origin":origin,"allow_local_development_certificate":false});
            assert!(parse_profile(&p.to_string()).is_err());
        }
        let remote = serde_json::json!({"user_api_origin":"https://server.test","allow_local_development_certificate":true});
        assert!(parse_profile(&remote.to_string()).is_err());
        let (_, endpoint) = profile().expect("reviewed default");
        assert!(transport(Some("-----BEGIN PRIVATE KEY-----"), &endpoint).is_err());
        let (_,public)=parse_profile(r#"{"user_api_origin":"https://server.test","allow_local_development_certificate":false}"#).expect("deployment");
        assert!(transport(Some("custom root"), &public).is_err());
    }
    #[test]
    fn bearer_shape_is_exact_and_header_is_sensitive() {
        let t = format!("oa1.{}.{}", Uuid::new_v4(), "a".repeat(64));
        assert!(authorization(&t).expect("scoped token").is_sensitive());
        for token in ["", "Bearer token", &format!("{t} "), &t.to_uppercase()] {
            assert!(authorization(token).is_err());
        }
    }
}
