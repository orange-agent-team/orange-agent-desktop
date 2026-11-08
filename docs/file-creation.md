# Desktop create-only capability — integration candidate

This worktree is implementing the desktop consumer of the server-owned Runtime creation capability. It is not yet a verified desktop release. The formal desktop remains the protected-path Runtime build until source, widget, native and packaging checks pass.

## Permission and execution sequence

1. The user selects a readonly workspace through the existing workflow.
2. The separate creation panel opens a native directory chooser. Rust requires the same canonical directory and physical resource as that readonly workspace. It refuses protected roots and closed selection IDs.
3. Durable creation consent is distinct from the native selection lifetime. The UI retains the selection ID before dispatch so a lost response can be cleaned up. It must await Runtime suspension/drain before releasing the native scope.
4. New conversations default to readonly tools. An explicit checkbox calls `start_creation_run` with the exact consent ID/version. An uncertain start retries the same original Run ID, prompt and capability; existing readonly Runs cannot be upgraded.
5. A `write_file` proposal displays the actual relative path and complete UTF-8 content. Empty files are explicitly labelled. Unsupported/malformed previews cannot be approved. Only `approve_creation_tool` grants the exact operation/digest, with bounded expiry; ordinary `approve_tool` cannot grant writes.
6. Runtime creates a new file with no-replace publication, never overwrites an existing destination, and commits a receipt before model context advances. Later content-bearing reads revalidate the real created file. Deletion or alteration hides cached results.

The contract is create-only, bounded to64 KiB UTF-8 without NUL. It does not expose editing, deletion, shell execution or directory creation. These remain separate future capabilities, not successful stubs.

## Host and FRB surface

`CreationAccessView` carries consent/workspace identity, display path, permission version/active flag, and optional current native session token. `AgentRunView.creation_consent_id` is immutable Runtime metadata; the UI must never infer granted capability merely from a pending tool name.

Commands are `authorize_creation_access`, `list_creation_access`, `suspend_creation_selection`, `revoke_creation_access`, `start_creation_run`, and `approve_creation_tool`. The shared Runtime exposes `agent_creation_requirement(owner,run)` for authenticated recovery metadata without granting access. All commands run under the existing single Journal owner; revocation/cancellation signals are sent before waiting for its queue.

Creation scope release cancels only Runs bound to that consent. Independent readonly Runs remain available. Replacing a native selection drains the prior grant; late cleanup for the old token cannot close its replacement. Revocation uses the exact consent version and is acknowledged only after durable commit and drain. Read-scope suspension also stops paired creation permits and awaits them before releasing native access. Unknown publication outcomes remain quarantined by Runtime and cannot be bypassed with new consent.

## macOS boundary

The app needs the user-selected read/write entitlement for explicit file creation. Apple documents this as application access to resources chosen with Open/Save dialogs; it is not a per-Run Orange Agent capability. Consequently, the UI describes readonly **Agent tools**, not a claim that the whole process has OS-enforced readonly access. [Apple entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write).

No persistent bookmark capability is added here. Apple provides read-only scoped bookmark options, but those options do not establish revocation of other already-acquired process rights. We do not infer that guarantee. [Apple bookmark option documentation](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/securityscopeallowonlyreadaccess).

Windows and Linux picker/publication certification remains pending. Native callback fixtures prove the bridge and filesystem workflow on owned test directories; they do not certify an actual external-directory picker grant, persistent bookmarks, production signing or process-level sandbox least privilege.

## Validation and remaining work

The isolated Rust actor suite covers explicit creation intent/approval, refusal of readonly upgrades, exact digest and scope replacement, actual file publication, created-source deletion, cancellation during a model wait, and independent readonly continuation. The same process-global actor test owns all actor scenarios to avoid concurrent singleton interference.

Dart tests exercise default-off capability selection, immutable retry consent, complete file preview, distinct write approval, malformed-preview refusal, and content clearing on consent stop. A native integration scenario is being added with actual Flutter/FRB/private IPC/SQLite/new-file effects and explicit model/picker fixtures. The combined non-native check now passes9 Rust tests, strict Clippy, generation/source checks and17 widget tests. Full native tests, packaging, scope-lifetime review and actual OS chooser verification remain required before merge.

Final imported Runtime7e115c3 passes125 shared tests. The5 packaged macOS native scenarios now pass, including actual read→approved creation→final result and created-source deletion clearing. The exact Runtime commit assertion was updated from the previous6b6c08b release; its initial mismatch is preserved as failed evidence. Native selectors and model protocol remain explicit fixtures in that suite. The separate `integration_test/manual_creation_entry.dart` is a QA-only target for real native picker verification with fixture model responses; it is never the default product entry.
