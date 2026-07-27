use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use liaison_protocol::{
    Command, CommandOutput, Request, Response, ResponseData, WorkspaceExecRequest,
    MAX_MESSAGE_BYTES,
};
use thiserror::Error;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub struct LiaisonClient {
    address: String,
    token: String,
    timeout: Duration,
}

impl LiaisonClient {
    pub fn new(address: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            address: address.into(),
            token: token.into(),
            timeout: Duration::from_secs(5),
        }
    }

    pub fn from_environment() -> Self {
        let (saved_address, saved_token) = load_saved_connection().unwrap_or_default();
        Self::new(
            std::env::var("LIAISON_ADDRESS")
                .ok()
                .or(saved_address)
                .unwrap_or_else(|| "127.0.0.1:57841".to_owned()),
            std::env::var("LIAISON_TOKEN")
                .ok()
                .or(saved_token)
                .unwrap_or_else(|| "change-this-token-before-production".to_owned()),
        )
    }

    pub fn address(&self) -> &str {
        &self.address
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn send(&self, command: Command) -> Result<ResponseData, ClientError> {
        let request_id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        self.send_request(
            Request::new(request_id, self.token.clone(), command),
            self.timeout,
        )
    }

    pub fn exec_workspace(
        &self,
        slot_id: impl Into<String>,
        command: impl Into<String>,
        working_directory: impl Into<String>,
    ) -> Result<CommandOutput, ClientError> {
        let request_id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let request = Request::workspace_exec(
            request_id,
            self.token.clone(),
            WorkspaceExecRequest {
                slot_id: slot_id.into(),
                command: command.into(),
                working_directory: working_directory.into(),
            },
        );
        match self.send_request(request, Duration::from_secs(60))? {
            ResponseData::CommandOutput(output) => Ok(output),
            _ => Err(ClientError::Protocol(
                "workspace request returned an unexpected response".to_owned(),
            )),
        }
    }

    fn send_request(
        &self,
        request: Request,
        timeout: Duration,
    ) -> Result<ResponseData, ClientError> {
        let request_id = request.request_id;
        let address = self
            .address
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| ClientError::Protocol("address did not resolve".to_owned()))?;
        let mut stream = TcpStream::connect_timeout(&address, timeout)?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        let mut payload = serde_json::to_vec(&request)?;
        payload.push(b'\n');
        stream.write_all(&payload)?;
        stream.flush()?;

        let reader = BufReader::new(stream);
        let mut line = String::new();
        let read = reader
            .take(MAX_MESSAGE_BYTES as u64)
            .read_line(&mut line)?;
        if read == 0 {
            return Err(ClientError::Protocol(
                "service closed the connection without a response".to_owned(),
            ));
        }
        let response: Response = serde_json::from_str(&line)?;
        if response.request_id != request_id {
            return Err(ClientError::Protocol(
                "response request_id did not match".to_owned(),
            ));
        }
        if !response.ok {
            let error = response.error.unwrap_or(liaison_protocol::ApiError {
                code: "unknown".to_owned(),
                message: "service returned an unspecified error".to_owned(),
            });
            return Err(ClientError::Remote {
                code: error.code,
                message: error.message,
            });
        }
        response.data.ok_or_else(|| {
            ClientError::Protocol("successful response did not contain data".to_owned())
        })
    }
}

fn load_saved_connection() -> Option<(Option<String>, Option<String>)> {
    let path = std::env::var("LIAISON_CLIENT_CONFIG")
        .map(PathBuf::from)
        .ok()
        .or_else(default_client_config_path)?;
    let text = fs::read_to_string(path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    Some((
        value
            .get("address")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        value
            .get("token")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    ))
}

fn default_client_config_path() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        return std::env::var("APPDATA")
            .ok()
            .map(PathBuf::from)
            .map(|path| path.join("Liaison").join("client.json"));
    }
    #[cfg(target_os = "macos")]
    {
        return std::env::var("HOME").ok().map(PathBuf::from).map(|path| {
            path.join("Library")
                .join("Application Support")
                .join("Liaison")
                .join("client.json")
        });
    }
    #[cfg(all(not(windows), not(target_os = "macos")))]
    {
        std::env::var("XDG_CONFIG_HOME")
            .ok()
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .map(PathBuf::from)
                    .map(|path| path.join(".config"))
            })
            .map(|path| path.join("liaison").join("client.json"))
    }
}

#[derive(Debug, Error)]
pub enum ClientError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("service rejected the request ({code}): {message}")]
    Remote { code: String, message: String },
}

#[cfg(test)]
mod tests {
    use std::{net::TcpListener, thread};

    use liaison_protocol::{HealthStatus, PROTOCOL_VERSION};

    use super::*;

    #[test]
    fn client_sends_one_line_request_and_reads_response() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            let request: Request = serde_json::from_str(&line).unwrap();
            let response = Response::success(
                request.request_id,
                ResponseData::Health(HealthStatus {
                    service: "liaison".to_owned(),
                    version: "test".to_owned(),
                    runtime: "mock".to_owned(),
                }),
            );
            assert_eq!(response.protocol_version, PROTOCOL_VERSION);
            writeln!(stream, "{}", serde_json::to_string(&response).unwrap()).unwrap();
        });
        let client = LiaisonClient::new(address.to_string(), "0123456789abcdef");
        let data = client.send(Command::Health).unwrap();
        assert!(matches!(data, ResponseData::Health(_)));
        server.join().unwrap();
    }

    #[test]
    fn workspace_request_returns_output() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            let request: Request = serde_json::from_str(&line).unwrap();
            assert!(request.workspace_exec.is_some());
            let response = Response::success(
                request.request_id,
                ResponseData::CommandOutput(CommandOutput {
                    slot_id: "W1".to_owned(),
                    command: "pwd".to_owned(),
                    working_directory: "/workspace".to_owned(),
                    exit_code: 0,
                    stdout: "/workspace\n".to_owned(),
                    stderr: String::new(),
                    truncated: false,
                }),
            );
            writeln!(stream, "{}", serde_json::to_string(&response).unwrap()).unwrap();
        });
        let client = LiaisonClient::new(address.to_string(), "0123456789abcdef");
        let output = client.exec_workspace("W1", "pwd", "/workspace").unwrap();
        assert_eq!(output.stdout, "/workspace\n");
        server.join().unwrap();
    }
}
