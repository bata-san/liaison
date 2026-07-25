#[cfg(windows)]
mod platform {
    use std::{
        ffi::OsString,
        sync::mpsc,
        time::Duration,
    };

    use windows_service::{
        define_windows_service,
        service::{
            ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState,
            ServiceStatus, ServiceType,
        },
        service_control_handler::{self, ServiceControlHandlerResult},
        service_dispatcher,
    };

    const SERVICE_NAME: &str = "LiaisonService";

    define_windows_service!(ffi_service_main, service_main);

    pub fn run() -> windows_service::Result<()> {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)
    }

    fn service_main(_arguments: Vec<OsString>) {
        if let Err(error) = run_service() {
            tracing::error!(%error, "service stopped with an error");
        }
    }

    fn run_service() -> windows_service::Result<()> {
        let (shutdown_tx, shutdown_rx) = mpsc::channel();

        let status_handle = service_control_handler::register(
            SERVICE_NAME,
            move |event| match event {
                ServiceControl::Stop => {
                    let _ = shutdown_tx.send(());
                    ServiceControlHandlerResult::NoError
                }
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                _ => ServiceControlHandlerResult::NotImplemented,
            },
        )?;

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;

        tracing::info!("Liaison service started");

        loop {
            match shutdown_rx.recv_timeout(Duration::from_secs(10)) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    tracing::trace!("service heartbeat");
                }
            }
        }

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;

        Ok(())
    }
}

fn main() {
    tracing_subscriber::fmt()
        .with_target(false)
        .compact()
        .init();

    #[cfg(windows)]
    if let Err(error) = platform::run() {
        tracing::error!(%error, "failed to start Windows service dispatcher");
        std::process::exit(1);
    }

    #[cfg(not(windows))]
    tracing::warn!("liaison-service is intended to run as a Windows service");
}
