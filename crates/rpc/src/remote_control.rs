//! Device-room host relay admission (Settings → Devices → Allow remote control).
//!
//! The host relay serves the same [`RpcService`] the local IPC socket does. A
//! compromised edge that can inject frames into a live host socket would
//! otherwise get a full ControlRpc surface on every synced computer. Admission
//! is a pure function of the device-local preference and the method name so
//! tests can pin the gate without a Durable Object.

use crate::methods;

/// Whether a method may run on the host-relay RPC surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayAdmit {
    /// Serve it. Either remote control is on, or the method is a liveness /
    /// status probe that must work so a phone can see the setting.
    Allow,
    /// User has not enabled Settings → Devices → Allow remote control.
    RemoteControlOff,
    /// Never served over the relay, even when remote control is on. Changing
    /// the gate itself from the relay would let a compromised edge turn the
    /// computer into a remotely driven host.
    LocalOnly,
}

/// Error text when [`RelayAdmit::RemoteControlOff`].
pub const REMOTE_CONTROL_OFF: &str =
    "Remote control is off on this computer. Enable it in Settings → Devices.";

/// Error text when [`RelayAdmit::LocalOnly`].
pub const RELAY_LOCAL_ONLY: &str = "This action can only be done on the computer itself.";

/// Methods the host relay may serve while remote control is off. `ListHarnesses`
/// is the peer-link readiness probe; `GetRemoteControl` lets another device
/// show that this computer has not opted in. Everything else is execution,
/// filesystem, terminals, or settings mutation.
fn relay_probe_method(method: &str) -> bool {
    matches!(
        method,
        methods::GET_REMOTE_CONTROL
            | methods::LIST_HARNESSES
            | methods::ENGINE_INFO
            | methods::ENGINE_READY
    )
}

/// Admit one ControlRpc method on the device-room **host** socket.
///
/// Local IPC is unrestricted: the GUI on this computer still talks to the
/// engine over `127.0.0.1`. This gate applies only to frames that arrived
/// through the edge relay.
pub fn admit_relay_rpc(remote_control: bool, method: &str) -> RelayAdmit {
    if method == methods::SET_REMOTE_CONTROL {
        return RelayAdmit::LocalOnly;
    }
    if remote_control || relay_probe_method(method) {
        RelayAdmit::Allow
    } else {
        RelayAdmit::RemoteControlOff
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_command_is_refused_until_remote_control_is_on() {
        assert_eq!(
            admit_relay_rpc(false, methods::QUEUE_COMMAND),
            RelayAdmit::RemoteControlOff
        );
        assert_eq!(
            admit_relay_rpc(true, methods::QUEUE_COMMAND),
            RelayAdmit::Allow
        );
    }

    #[test]
    fn terminals_and_file_writes_follow_the_same_gate() {
        for method in [
            methods::OPEN_TERMINAL,
            methods::WRITE_TERMINAL,
            methods::WRITE_WORKSPACE_FILE,
            methods::RELAY_COMMAND,
            methods::SET_AUTONOMY,
            methods::APPLY_UPDATE,
            methods::MCP_SERVER_ACTION,
        ] {
            assert_eq!(
                admit_relay_rpc(false, method),
                RelayAdmit::RemoteControlOff,
                "{method}"
            );
            assert_eq!(admit_relay_rpc(true, method), RelayAdmit::Allow, "{method}");
        }
    }

    #[test]
    fn probes_work_while_remote_control_is_off() {
        for method in [
            methods::GET_REMOTE_CONTROL,
            methods::LIST_HARNESSES,
            methods::ENGINE_INFO,
            methods::ENGINE_READY,
        ] {
            assert_eq!(
                admit_relay_rpc(false, method),
                RelayAdmit::Allow,
                "{method}"
            );
        }
    }

    #[test]
    fn set_remote_control_is_never_served_over_the_relay() {
        assert_eq!(
            admit_relay_rpc(false, methods::SET_REMOTE_CONTROL),
            RelayAdmit::LocalOnly
        );
        assert_eq!(
            admit_relay_rpc(true, methods::SET_REMOTE_CONTROL),
            RelayAdmit::LocalOnly
        );
    }
}
