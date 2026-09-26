//! Links a WhatsApp account and records every event for fixtures. Never sends anything.
//!
//!   cargo run --release                 # QR in terminal
//!   cargo run --release -- -p 4915...   # phone-number pair code (digits, with country code)
//!
//! Output: ~/Library/Application Support/BetterWA/
//!   wa-session.sqlite            library session/keys (reused by the app's bridge)
//!   capture/events.jsonl         one JSON event per line
//!   capture/history/*.zlib       raw HistorySync payloads (zlib-compressed protobuf)
#![recursion_limit = "512"]

use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use qrcode::QrCode;
use qrcode::render::unicode::Dense1x2;
use whatsapp_rust::pair_code::PairCodeOptions;
use whatsapp_rust::prelude::*;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();

    let args: Vec<String> = std::env::args().collect();
    let phone = args
        .iter()
        .position(|a| a == "-p" || a == "--phone")
        .and_then(|i| args.get(i + 1).cloned());

    let base = PathBuf::from(std::env::var("HOME")?).join("Library/Application Support/BetterWA");
    let history_dir = base.join("capture/history");
    fs::create_dir_all(&history_dir)?;
    let session = base.join("wa-session.sqlite");
    let events_path = base.join("capture/events.jsonl");
    let events = Arc::new(Mutex::new(BufWriter::new(
        OpenOptions::new().create(true).append(true).open(&events_path)?,
    )));
    let count = Arc::new(AtomicU64::new(0));

    println!("session: {}", session.display());
    println!("capture: {}", events_path.display());

    let store = SqliteStore::new(session.to_str().unwrap()).await?;
    let mut builder = Bot::builder()
        .with_backend(store)
        .with_event_delivery(EventDelivery::Ordered { capacity: 65_536 })
        .on_qr_code(|code, timeout| async move {
            let qr = QrCode::new(code.as_bytes()).expect("qr");
            let img = qr.render::<Dense1x2>().quiet_zone(true).build();
            println!("\n{img}\nScan in WhatsApp → Settings → Linked Devices → Link a Device (valid {}s)\n", timeout.as_secs());
        })
        .on_pair_code(|code, timeout| async move {
            println!("\nPAIR CODE: {code}  (valid {}s)\nWhatsApp → Linked Devices → Link a Device → Link with phone number instead\n", timeout.as_secs());
        })
        .on_event({
            let events = events.clone();
            let count = count.clone();
            let history_dir = history_dir.clone();
            move |event, _client| {
                let events = events.clone();
                let count = count.clone();
                let history_dir = history_dir.clone();
                async move {
                    let n = count.fetch_add(1, Ordering::Relaxed);
                    let line = match &*event {
                        Event::HistorySync(h) => {
                            let name = format!(
                                "{n:06}-type{}-chunk{}.zlib",
                                h.sync_type(),
                                h.chunk_order().unwrap_or(0)
                            );
                            if let Err(e) = File::create(history_dir.join(&name))
                                .and_then(|mut f| f.write_all(h.compressed_bytes()))
                            {
                                eprintln!("history write failed: {e}");
                            }
                            println!(
                                "history sync: type {} chunk {:?} progress {:?}% ({} bytes inflated)",
                                h.sync_type(),
                                h.chunk_order(),
                                h.progress(),
                                h.decompressed_size()
                            );
                            serde_json::json!({ "HistorySyncFile": name }).to_string()
                        }
                        Event::Connected(_) => {
                            println!("connected");
                            serde_json::to_string(&*event).unwrap_or_default()
                        }
                        Event::LoggedOut(_) => {
                            println!("LOGGED OUT");
                            serde_json::to_string(&*event).unwrap_or_default()
                        }
                        Event::PairSuccess(_) => {
                            println!("paired ✅ — waiting for history sync, keep this running");
                            serde_json::to_string(&*event).unwrap_or_default()
                        }
                        _ => serde_json::to_string(&*event)
                            .unwrap_or_else(|e| format!("{{\"serializeError\":\"{e}\"}}")),
                    };
                    let mut w = events.lock().unwrap();
                    let _ = writeln!(w, "{line}");
                    let _ = w.flush();
                    if n % 500 == 0 && n > 0 {
                        println!("{n} events captured");
                    }
                }
            }
        });

    if let Some(phone_number) = phone {
        builder = builder.with_pair_code(PairCodeOptions {
            phone_number,
            ..Default::default()
        });
    }

    let bot = builder.build().await?;
    let mut handle = bot.spawn();
    tokio::select! {
        _ = &mut handle => {}
        _ = tokio::signal::ctrl_c() => {
            println!("shutting down…");
            handle.shutdown().await;
        }
    }
    println!("{} events captured total", count.load(Ordering::Relaxed));
    Ok(())
}
