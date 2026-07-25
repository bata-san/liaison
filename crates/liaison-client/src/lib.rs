use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use liaison_protocol::{Command, Request, Response, ResponseData, MAX_MESSAGE_BYTES};
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
        Self::new(
            std::env::var("LIAISON_ADDRESS").unwrap_or_else(|_| "127.0.0.1:57841".to_owned()),
            std::env::var("LIAISON_TOKEN").unwrap_or_else(|_| "change-this-token-before-production".to_owned()),
        )
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn send(&self, command: Command) -> Result<ResponseData, ClientError> {
        let request_id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let request = Request::new(request_id, self.token.clone(), command);
        let address = self.address.to_socket_addrs()?.next()
            .ok_or_else(|| ClientError::Protocol("address did not resolve".to_owned()))?;
        let mut stream = TcpStream::connect_timeout(&address, self.timeout)?;
        stream.set_read_timeout(Some(self.timeout))?;
        stream.set_write_timeout(Some(self.timeout))?;
        let mut payload = serde_json::to_vec(&request)?;
        payload.push(b'\n');
        stream.write_all(&payload)?;
        stream.flush()?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        let read = reader.take(MAX_MESSAGE_BYTES as u64).read_line(&mut line)?;
        if read == 0 {
            return Err(ClientError::Protocol("service closed the connection without a response".to_owned()));
        }
        let response: Response = serde_json::from_str(&line)?;
        if response.request_id != request_id {
            return Err(ClientError::Protocol("response request_id did not match".to_owned()));
        }
        if !response.ok {
            let error = response.error.unwrap_or(liaison_protocol::ApiError {
                code: "unknown".to_owned(),
                message: "service returned an unspecified error".to_owned(),
            });
            return Err(ClientError::Remote { code: error.code, message: error.message });
        }
        response.data.ok_or_else(|| ClientError::Protocol("successful response did not contain data".to_owned()))
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
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
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
}
