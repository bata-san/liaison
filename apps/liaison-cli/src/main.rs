use liaison_client::LiaisonClient;
use liaison_core::{GpuAccess, OperatingMode, ResourceAllocation};
use liaison_protocol::{Command, ResponseData};

fn main() {
    if let Err(error) = run() {
        eprintln!("liaison-cli: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut address = std::env::var("LIAISON_ADDRESS").unwrap_or_else(|_| "127.0.0.1:57841".to_owned());
    let mut token = std::env::var("LIAISON_TOKEN").unwrap_or_else(|_| "change-this-token-before-production".to_owned());
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    while args.first().is_some_and(|value| value.starts_with("--")) {
        match args.remove(0).as_str() {
            "--address" => address = take_value(&mut args, "--address")?,
            "--token" => token = take_value(&mut args, "--token")?,
            "--help" => return Err(usage().into()),
            option => return Err(format!("unknown option: {option}\n{}", usage()).into()),
        }
    }

    let command_name = args.first().map(String::as_str).unwrap_or("health");
    let command = match command_name {
        "health" => Command::Health,
        "snapshot" => Command::Snapshot,
        "mode" => {
            let value = args.get(1).ok_or("mode requires remote, class, local-exclusive, or maintenance")?;
            Command::SetMode { mode: parse_mode(value)? }
        }
        "start" => Command::StartSlot { slot_id: args.get(1).ok_or("start requires a slot id")?.clone() },
        "stop" => Command::StopSlot { slot_id: args.get(1).ok_or("stop requires a slot id")?.clone() },
        "rebalance" => {
            let count = args.get(1).ok_or("rebalance requires a slot count")?.parse::<u8>()?;
            Command::Rebalance { active_workspace_slots: count }
        }
        "resize" => {
            let slot_id = args.get(1).ok_or("resize requires SLOT CPU_THREADS MEMORY_MIB")?.clone();
            let cpu_threads = args.get(2).ok_or("resize requires SLOT CPU_THREADS MEMORY_MIB")?.parse::<u16>()?;
            let memory_mib = args.get(3).ok_or("resize requires SLOT CPU_THREADS MEMORY_MIB")?.parse::<u32>()?;
            Command::ResizeSlot {
                slot_id,
                allocation: ResourceAllocation { cpu_threads, memory_mib, gpu: GpuAccess::None },
            }
        }
        "gpu" => {
            let slot_id = args.get(1).ok_or("gpu requires a workspace slot id")?.clone();
            let access = match args.get(2).map(String::as_str).unwrap_or("exclusive") {
                "shared" => GpuAccess::Shared,
                "exclusive" => GpuAccess::Exclusive,
                value => return Err(format!("unknown GPU mode: {value}").into()),
            };
            Command::ReserveGpu { slot_id, access }
        }
        "release-gpu" => Command::ReleaseGpu,
        "help" | "--help" | "-h" => return Err(usage().into()),
        value => return Err(format!("unknown command: {value}\n{}", usage()).into()),
    };

    let data = LiaisonClient::new(address, token).send(command)?;
    match data {
        ResponseData::Ack => println!("ok"),
        ResponseData::Health(health) => println!("{}", serde_json::to_string_pretty(&health)?),
        ResponseData::Snapshot(snapshot) => println!("{}", serde_json::to_string_pretty(&snapshot)?),
    }
    Ok(())
}

fn take_value(args: &mut Vec<String>, option: &str) -> Result<String, Box<dyn std::error::Error>> {
    if args.is_empty() {
        return Err(format!("{option} requires a value").into());
    }
    Ok(args.remove(0))
}

fn parse_mode(value: &str) -> Result<OperatingMode, Box<dyn std::error::Error>> {
    match value {
        "remote" => Ok(OperatingMode::Remote),
        "class" => Ok(OperatingMode::Class),
        "local-exclusive" | "local_exclusive" => Ok(OperatingMode::LocalExclusive),
        "maintenance" => Ok(OperatingMode::Maintenance),
        _ => Err(format!("unknown operating mode: {value}").into()),
    }
}

fn usage() -> &'static str {
    "Usage: liaison-cli [--address HOST:PORT] [--token TOKEN] COMMAND\n\nCommands:\n  health\n  snapshot\n  mode remote|class|local-exclusive|maintenance\n  start SLOT\n  stop SLOT\n  rebalance 0..5\n  resize SLOT CPU_THREADS MEMORY_MIB\n  gpu SLOT [shared|exclusive]\n  release-gpu"
}
