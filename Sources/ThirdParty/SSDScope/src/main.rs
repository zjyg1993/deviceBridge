// Capture, packet validation and offline decoding adapted from SSD Scope for Mac.
mod command;
mod disks;
mod native;
mod smart;
mod usb_access;
mod usb_report;
mod usb_safety;
mod usb_sat;

use anyhow::{Result, bail, ensure};
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};

static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

fn run() -> Result<()> {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    match arguments.as_slice() {
        [action] if action == "inventory" => {
            println!("{}", serde_json::to_string(&disks::display_inventory()?)?);
        }
        [action, disk] if action == "probe" => {
            println!("{}", serde_json::to_string(&usb_access::plan(disk)?)?);
        }
        [action, disk, registry] if action == "capture" => {
            ensure!(
                std::env::vars_os().all(|(key, _)| !key.to_string_lossy().starts_with("DYLD_")),
                "Loader overrides are not allowed"
            );
            unsafe {
                libc::signal(libc::SIGINT, cancel as *const () as libc::sighandler_t);
                libc::signal(libc::SIGTERM, cancel as *const () as libc::sighandler_t);
            }
            let snapshot = usb_access::capture(disk, registry.parse()?, &CANCELLED)?;
            println!("{}", serde_json::to_string(&snapshot)?);
        }
        [action] if action == "decode" => {
            let mut input = Vec::new();
            io::stdin().take(65537).read_to_end(&mut input)?;
            ensure!(input.len() <= 65536, "Capture is too large");
            let raw = serde_json::from_slice(&input)?;
            let snapshot = usb_report::decode(&raw, &command::Control::default())?;
            println!("{}", serde_json::to_string(&snapshot)?);
        }
        _ => bail!("Expected inventory, probe DISK, capture DISK REGISTRY, or decode"),
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
