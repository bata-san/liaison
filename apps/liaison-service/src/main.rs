mod app;
mod server;

use std::{
    path::PathBuf,
    sync::{atomic::AtomicBool, Arc},
    time::Duration,
};

use app::ServiceApp;
use liaison_core::{detected_cpu_threads, AppConfig, RuntimeKind};
use liaison_runtime::{MockRuntime, RuntimeAdapter, WslDockerRuntime};

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("liaison=info".parse().unwrap()),
        )
        .with_target(false)
        .compact()
        .init();

    let options = match Options::parse() {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };

    if options.print_default_config {
        println!(
            "{}",
            serde_json::to_string_pretty(&AppConfig::default())
                .expect("default config is serializable")
        );
        return;
    }

    #[cfg(windows)]
    if !options.console {
        if let Err(error) = windows_host::run() {
            tracing::error!(%error, "failed to start Liaison as a Windows service");
            std::process::exit(1);
        }
        return;
    }

    if let Err(error) = run_console(options) {
        tracing::error!(%error, "Liaison console host stopped");
        std::process::exit(1);
    }
}

fn run_console(options: Options) -> Result<(), Box<dyn std::error::Error>> {
    let mut config = AppConfig::load_or_create(&options.config_path)?;
    if let Some(runtime) = options.runtime_override {
        config.runtime = runtime;
    }
    let shutdown = Arc::new(AtomicBool::new(false));
    run_with_config(config, shutdown)
}

fn run_with_config(
    mut config: AppConfig,
    shutdown: Arc<AtomicBool>,
) -> Result<(), Box<dyn std::error::Error>> {
    config.validate()?;
    let runtime: Arc<dyn RuntimeAdapter> = match config.runtime {
        RuntimeKind::Mock => Arc::new(MockRuntime::new()),
        RuntimeKind::WslDocker => Arc::new(WslDockerRuntime::new(
            config.wsl_distribution.clone(),
            config.workspace_image.clone(),
            config.persistent_image.clone(),
        )),
    };

    if config.auto_tune {
        let host = runtime.collect_host_metrics();
        let host_cpu_threads = detected_cpu_threads();
        config.tune_for_host(host_cpu_threads, host.memory_total_mib);
        config.validate()?;
        tracing::info!(
            host_cpu_threads,
            host_memory_mib = host.memory_total_mib,
            persistent_cpu = config.persistent_pool.cpu_threads,
            persistent_memory_mib = config.persistent_pool.memory_mib,
            workspace_cpu = config.workspace_pool.cpu_threads,
            workspace_memory_mib = config.workspace_pool.memory_mib,
            max_workspace_slots = config.max_workspace_slots,
            "auto-tuned resource pools for detected host"
        );
    }

    let app = Arc::new(ServiceApp::new(config.clone(), runtime)?);
    let interval = Duration::from_millis(config.metrics_interval_ms.max(250));
    server::run(
        app,
        &config.listen_address,
        Arc::new(config.auth_token),
        shutdown,
        interval,
    )?;
    Ok(())
}

#[derive(Debug)]
struct Options {
    console: bool,
    config_path: PathBuf,
    runtime_override: Option<RuntimeKind>,
    print_default_config: bool,
}

impl Options {
    fn parse() -> Result<Self, String> {
        let mut console = false;
        let mut config_path = default_config_path();
        let mut runtime_override = None;
        let mut print_default_config = false;
        let mut arguments = std::env::args().skip(1);
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--console" => console = true,
                "--config" => {
                    let path = arguments.next().ok_or("--config requires a path")?;
                    config_path = PathBuf::from(path);
                }
                "--runtime" => {
                    let runtime = arguments
                        .next()
                        .ok_or("--runtime requires mock or wsl-docker")?;
                    runtime_override = Some(match runtime.as_str() {
                        "mock" => RuntimeKind::Mock,
                        "wsl-docker" => RuntimeKind::WslDocker,
                        _ => return Err("--runtime must be mock or wsl-docker".to_owned()),
                    });
                }
                "--print-default-config" => print_default_config = true,
                "--help" | "-h" => {
                    return Err(
                        "Usage: liaison-service [--console] [--config PATH] [--runtime mock|wsl-docker] [--print-default-config]"
                            .to_owned(),
                    )
                }
                value => return Err(format!("unknown argument: {value}")),
            }
        }
        Ok(Self {
            console,
            config_path,
            runtime_override,
            print_default_config,
        })
    }
}

fn default_config_path() -> PathBuf {
    if let Ok(path) = std::env::var("LIAISON_CONFIG") {
        return PathBuf::from(path);
    }
    #[cfg(windows)]
    {
        let program_data =
            std::env::var("PROGRAMDATA").unwrap_or_else(|_| "C:\\ProgramData".to_owned());
        return PathBuf::from(program_data)
            .join("Liaison")
            .join("liaison.json");
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("liaison.local.json")
    }
}

#[cfg(windows)]
mod windows_host {
    use std::{
        ffi::OsString,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        time::Duration,
    };

    use windows_service::{
        define_windows_service,
        service::{
            ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
            ServiceType,
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
        if let Err(error) = run_inner() {
            tracing::error!(%error, "Windows service host failed");
        }
    }

    fn run_inner() -> Result<(), Box<dyn std::error::Error>> {
        let shutdown = Arc::new(AtomicBool::new(false));
        let handler_shutdown = Arc::clone(&shutdown);
        let status_handle = service_control_handler::register(SERVICE_NAME, move |event| {
            match event {
                ServiceControl::Stop => {
                    handler_shutdown.store(true, Ordering::Relaxed);
                    ServiceControlHandlerResult::NoError
                }
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        })?;

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;

        let config = liaison_core::AppConfig::load_or_create(&super::default_config_path())?;
        let result = super::run_with_config(config, shutdown);

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;
        result
    }
}
