use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::Duration,
};

use liaison_protocol::{
    CommandOutput, Request, Response, ResponseData, WorkspaceExecRequest, MAX_MESSAGE_BYTES,
    PROTOCOL_VERSION,
};
use liaison_runtime::RuntimeAdapter;

use crate::app::ServiceApp;

pub fn run(
    app: Arc<ServiceApp>,
    runtime: Arc<dyn RuntimeAdapter>,
    address: &str,
    token: Arc<String>,
    shutdown: Arc<AtomicBool>,
    metrics_interval: Duration,
) -> Result<(), std::io::Error> {
    let listener = TcpListener::bind(address)?;
    listener.set_nonblocking(true)?;
    tracing::info!(%address, "Liaison control endpoint is listening");

    let metrics_shutdown = Arc::clone(&shutdown);
    let metrics_app = Arc::clone(&app);
    let metrics_thread = thread::spawn(move || {
        while !metrics_shutdown.load(Ordering::Relaxed) {
            metrics_app.refresh_metrics();
            thread::sleep(metrics_interval);
        }
    });

    while !shutdown.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, peer)) => {
                tracing::trace!(%peer, "accepted control connection");
                let request_app = Arc::clone(&app);
                let request_runtime = Arc::clone(&runtime);
                let request_token = Arc::clone(&token);
                thread::spawn(move || {
                    if let Err(error) = handle_connection(
                        stream,
                        &request_app,
                        &request_runtime,
                        &request_token,
                    ) {
                        tracing::warn!(%error, %peer, "control request failed");
                    }
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    }

    let _ = metrics_thread.join();
    Ok(())
}

fn handle_connection(
    mut stream: TcpStream,
    app: &ServiceApp,
    runtime: &Arc<dyn RuntimeAdapter>,
    token: &str,
) -> Result<(), std::io::Error> {
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    stream.set_write_timeout(Some(Duration::from_secs(15)))?;
    let mut line = String::new();
    let mut reader = BufReader::new(stream.try_clone()?);
    let bytes_read = reader
        .by_ref()
        .take(MAX_MESSAGE_BYTES as u64)
        .read_line(&mut line)?;
    if bytes_read == 0 {
        return Ok(());
    }

    let request: Request = match serde_json::from_str(&line) {
        Ok(request) => request,
        Err(error) => {
            write_response(
                &mut stream,
                &Response::failure(0, "invalid_json", error.to_string()),
            )?;
            return Ok(());
        }
    };

    let response = if request.protocol_version != PROTOCOL_VERSION {
        Response::failure(
            request.request_id,
            "protocol_version",
            "unsupported protocol version",
        )
    } else if !constant_time_eq(request.token.as_bytes(), token.as_bytes()) {
        Response::failure(
            request.request_id,
            "unauthorized",
            "invalid local control token",
        )
    } else if let Some(exec) = request.workspace_exec {
        workspace_response(request.request_id, runtime, exec)
    } else {
        match app.handle(request.command) {
            Ok(data) => Response::success(request.request_id, data),
            Err(error) => {
                Response::failure(request.request_id, "operation_failed", error.to_string())
            }
        }
    };
    write_response(&mut stream, &response)
}

fn workspace_response(
    request_id: u64,
    runtime: &Arc<dyn RuntimeAdapter>,
    request: WorkspaceExecRequest,
) -> Response {
    let slot_id = request.slot_id.trim().to_ascii_uppercase();
    if !matches!(slot_id.as_str(), "W1" | "W2" | "W3" | "W4" | "W5") {
        return Response::failure(
            request_id,
            "invalid_workspace",
            "workspace must be W1 through W5",
        );
    }

    let command = request.command.trim();
    if command.is_empty() {
        return Response::failure(request_id, "invalid_command", "command is empty");
    }
    if command.len() > 8_192 || command.contains('\0') {
        return Response::failure(
            request_id,
            "invalid_command",
            "command is too long or contains an invalid character",
        );
    }

    let working_directory = request.working_directory.trim();
    if working_directory != "/workspace"
        && !working_directory.starts_with("/workspace/")
        || working_directory.contains("..")
        || working_directory.contains('\0')
    {
        return Response::failure(
            request_id,
            "invalid_directory",
            "working directory must be /workspace or a child directory",
        );
    }

    match runtime.exec_workspace(&slot_id, command, working_directory) {
        Ok(output) => Response::success(
            request_id,
            ResponseData::CommandOutput(CommandOutput {
                slot_id,
                command: command.to_owned(),
                working_directory: working_directory.to_owned(),
                exit_code: output.exit_code,
                stdout: output.stdout,
                stderr: output.stderr,
                truncated: output.truncated,
            }),
        ),
        Err(error) => Response::failure(request_id, "workspace_failed", error.to_string()),
    }
}

fn write_response(stream: &mut TcpStream, response: &Response) -> Result<(), std::io::Error> {
    let mut bytes = serde_json::to_vec(response)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    stream.flush()
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let max = left.len().max(right.len());
    for index in 0..max {
        let a = left.get(index).copied().unwrap_or(0);
        let b = right.get(index).copied().unwrap_or(0);
        difference |= usize::from(a ^ b);
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_comparison_checks_length_and_content() {
        assert!(constant_time_eq(
            b"0123456789abcdef",
            b"0123456789abcdef"
        ));
        assert!(!constant_time_eq(
            b"0123456789abcdef",
            b"0123456789abcdeg"
        ));
        assert!(!constant_time_eq(b"short", b"shorter"));
    }

    #[test]
    fn workspace_directory_is_restricted() {
        let invalid = WorkspaceExecRequest {
            slot_id: "W1".to_owned(),
            command: "pwd".to_owned(),
            working_directory: "/etc".to_owned(),
        };
        let runtime: Arc<dyn RuntimeAdapter> = Arc::new(liaison_runtime::MockRuntime::new());
        let response = workspace_response(1, &runtime, invalid);
        assert!(!response.ok);
    }
}
