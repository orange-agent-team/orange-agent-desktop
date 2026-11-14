//! Consume helper stderr continuously but retain only allowlisted categories.
//! Raw stderr may contain private paths or credentials and is never persisted.
use super::*;
use tokio::io::AsyncRead;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum HelperFailure {
    None,
    ControlLost,
    BackendExited,
    Authentication,
    Other,
}
impl HelperFailure {
    pub(super) fn code(self) -> Option<&'static str> {
        match self {
            Self::None => None,
            Self::ControlLost => Some("MODEL_CONTROL_HEARTBEAT_LOST"),
            Self::BackendExited => Some("MODEL_BACKEND_EXITED"),
            Self::Authentication => Some("MODEL_CONTROL_AUTH_FAILED"),
            Self::Other => Some("MODEL_HELPER_DIAGNOSTIC"),
        }
    }
}
pub(super) async fn collect(mut input: impl AsyncRead + Unpin) -> HelperFailure {
    let mut buffer = [0; 1024];
    let mut tail = Vec::with_capacity(1152);
    let mut failure = HelperFailure::None;
    loop {
        let count = match input.read(&mut buffer).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => return HelperFailure::Other,
        };
        tail.extend_from_slice(&buffer[..count]);
        let text = String::from_utf8_lossy(&tail);
        let found = if text.contains("control channel ended without a valid frame") {
            HelperFailure::ControlLost
        } else if text.contains("backend exited") {
            HelperFailure::BackendExited
        } else if text.contains("private control authentication failed") {
            HelperFailure::Authentication
        } else {
            HelperFailure::Other
        };
        if matches!(failure, HelperFailure::None | HelperFailure::Other) {
            failure = found;
        }
        if tail.len() > 128 {
            tail.drain(..tail.len() - 128);
        }
    }
    failure
}
pub(super) fn failure_code(
    reason: HelperFailure,
    cause: Option<&str>,
    success: bool,
) -> Option<&str> {
    let classified = match reason {
        HelperFailure::Other => None,
        value => value.code(),
    };
    classified.or(cause).or(if success {
        None
    } else {
        Some("MODEL_HOST_EXITED")
    })
}
#[derive(Serialize)]
pub(super) struct FailureEvidence<'a> {
    pub schema: u8,
    pub instance: &'a str,
    pub cause: &'a str,
    pub helper_classification: Option<&'static str>,
    pub helper_exit_code: Option<i32>,
    pub helper_exit_signal: Option<i32>,
    pub last_ping_age_ms: u64,
    pub max_ping_gap_ms: u64,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_stops_and_unknown_stderr_do_not_invent_failure() {
        assert_eq!(failure_code(HelperFailure::None, None, true), None);
        assert_eq!(failure_code(HelperFailure::Other, None, true), None);
        assert_eq!(
            failure_code(
                HelperFailure::Other,
                Some("MODEL_CONTROL_SEND_FAILED"),
                false
            ),
            Some("MODEL_CONTROL_SEND_FAILED")
        );
        assert_eq!(
            failure_code(HelperFailure::ControlLost, Some("MODEL_HOST_EXITED"), false),
            Some("MODEL_CONTROL_HEARTBEAT_LOST")
        );
        assert_eq!(
            failure_code(HelperFailure::None, None, false),
            Some("MODEL_HOST_EXITED")
        );
    }
    #[tokio::test]
    async fn classification_handles_chunk_boundaries_without_preserving_raw_stderr() {
        let (mut writer, reader) = tokio::io::duplex(64);
        let sending = tokio::spawn(async move {
            writer
                .write_all(b"private path /secret and token=NEVER_PERSIST\ncontrol channel ended ")
                .await
                .expect("first chunk");
            writer
                .write_all(b"without a valid frame\n")
                .await
                .expect("second chunk");
        });
        let reason = collect(reader).await;
        sending.await.expect("sender");
        assert_eq!(reason, HelperFailure::ControlLost);
        let bytes = serde_json::to_vec(&FailureEvidence {
            schema: 1,
            instance: "owned",
            cause: "MODEL_HOST_EXITED",
            helper_classification: reason.code(),
            helper_exit_code: Some(1),
            helper_exit_signal: None,
            last_ping_age_ms: 31_000,
            max_ping_gap_ms: 31_000,
        })
        .expect("metadata");
        let value = String::from_utf8(bytes).expect("utf8");
        assert!(!value.contains("NEVER_PERSIST") && !value.contains("/secret"));
        assert_eq!(collect(&b""[..]).await, HelperFailure::None);
        assert_eq!(
            collect(&b"Error: backend exited"[..]).await,
            HelperFailure::BackendExited
        );
        assert_eq!(
            collect(&b"Error: private control authentication failed"[..]).await,
            HelperFailure::Authentication
        );
    }
}
