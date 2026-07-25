use liaison_core::{GpuAccess, OperatingMode, ResourceAllocation, SystemSnapshot};
use serde::{Deserialize, Serialize};

pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const PROTOCOL_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Request {
    pub protocol_version: u16,
    pub request_id: u64,
    pub token: String,
    pub command: Command,
}

impl Request {
    pub fn new(request_id: u64, token: impl Into<String>, command: Command) -> Self {
        Self { protocol_version: PROTOCOL_VERSION, request_id, token: token.into(), command }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    Health,
    Snapshot,
    SetMode { mode: OperatingMode },
    StartSlot { slot_id: String },
    StopSlot { slot_id: String },
    ResizeSlot { slot_id: String, allocation: ResourceAllocation },
    Rebalance { active_workspace_slots: u8 },
    ReserveGpu { slot_id: String, access: GpuAccess },
    ReleaseGpu,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Response {
    pub protocol_version: u16,
    pub request_id: u64,
    pub ok: bool,
    pub data: Option<ResponseData>,
    pub error: Option<ApiError>,
}

impl Response {
    pub fn success(request_id: u64, data: ResponseData) -> Self {
        Self { protocol_version: PROTOCOL_VERSION, request_id, ok: true, data: Some(data), error: None }
    }

    pub fn failure(request_id: u64, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: false,
            data: None,
            error: Some(ApiError { code: code.into(), message: message.into() }),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum ResponseData {
    Health(HealthStatus),
    Snapshot(SystemSnapshot),
    Ack,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HealthStatus {
    pub service: String,
    pub version: String,
    pub runtime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip_is_stable() {
        let request = Request::new(7, "0123456789abcdef", Command::Rebalance { active_workspace_slots: 3 });
        let json = serde_json::to_string(&request).unwrap();
        let decoded: Request = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, request);
    }
}
