//! Host-relay admission: remote control is off until the user opts in.
//!
//! `relay_rpc_refuses_queue_command_until_remote_control_is_on` fails on
//! main (the host relay used to serve QueueCommand with no opt-in).

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use harness_engine::{HarnessRegistry, RelayRpc};
use harness_rpc::{RpcError, RpcReply, RpcService, methods};

struct Inner;

#[async_trait]
impl RpcService for Inner {
    async fn handle(&self, method: &str, _params: serde_json::Value) -> Result<RpcReply, RpcError> {
        RpcReply::value(&json!({ "method": method }))
    }
}

#[tokio::test]
async fn relay_rpc_refuses_queue_command_until_remote_control_is_on() {
    let registry = Arc::new(HarnessRegistry::new());
    assert!(
        !registry.remote_control(),
        "a fresh computer must not be a remotely driven host"
    );
    let client = harness_rpc::memory_client(RelayRpc::wrap(Arc::new(Inner), registry.clone()));

    let err = client
        .call(methods::QUEUE_COMMAND, json!({}))
        .await
        .expect_err("QueueCommand over the relay must fail while remote control is off");
    assert!(err.to_string().contains("Remote control is off"), "{err}");

    let probe = client
        .call(methods::GET_REMOTE_CONTROL, json!({}))
        .await
        .expect("GetRemoteControl is a probe");
    assert_eq!(probe["method"], methods::GET_REMOTE_CONTROL);

    registry.set_remote_control(true);
    let queued = client
        .call(methods::QUEUE_COMMAND, json!({}))
        .await
        .expect("QueueCommand is served once the user opts in");
    assert_eq!(queued["method"], methods::QUEUE_COMMAND);
}

#[tokio::test]
async fn relay_rpc_never_lets_the_edge_flip_the_gate() {
    let registry = Arc::new(HarnessRegistry::new());
    registry.set_remote_control(true);
    let client = harness_rpc::memory_client(RelayRpc::wrap(Arc::new(Inner), registry.clone()));
    let err = client
        .call(methods::SET_REMOTE_CONTROL, json!({ "enabled": true }))
        .await
        .expect_err("SetRemoteControl must stay on local IPC");
    assert!(
        err.to_string().contains("only be done on the computer"),
        "{err}"
    );
    assert!(registry.remote_control());
}

#[tokio::test]
async fn local_ipc_can_change_remote_control() {
    let dir = tempfile::tempdir().expect("tempdir");
    let core = harness_engine::EngineCore::assemble(
        dir.path(),
        Arc::new(HarnessRegistry::new()),
        harness_proto::HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    let before = client
        .call(methods::GET_REMOTE_CONTROL, json!({}))
        .await
        .expect("GetRemoteControl");
    assert_eq!(before, json!({ "enabled": false }));
    let after = client
        .call(methods::SET_REMOTE_CONTROL, json!({ "enabled": true }))
        .await
        .expect("SetRemoteControl on local IPC");
    assert_eq!(after, json!({ "enabled": true }));
    assert!(core.registry.remote_control());
    let rejected = client
        .call(
            methods::SET_REMOTE_CONTROL,
            json!({ "enabled": false, "targetDeviceId": "some-other-computer" }),
        )
        .await
        .expect_err("SetRemoteControl must not retarget another device");
    assert!(
        rejected
            .to_string()
            .contains("only be done on the computer"),
        "{rejected}"
    );
    assert!(core.registry.remote_control());
    core.shutdown().await;
}
