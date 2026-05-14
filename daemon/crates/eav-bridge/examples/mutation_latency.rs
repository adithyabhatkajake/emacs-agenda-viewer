//! Quick mutation-latency benchmark against a running `eav-bridge.el`.
//!
//! Run with the bridge already up:
//!   cargo run --release --example mutation_latency -p eav-bridge
//!
//! Reports median / p99 latency for `write.set-priority` round trips, which
//! is a representative mutation (file open, edit, save, reply). Phase 4 exit
//! criterion is "<20 ms median, <50 ms p99 over a 10-min soak"; this runs a
//! shorter (60 s) sample by default.

use eav_bridge::BridgeClient;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::time::sleep;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let sock = std::env::var("EAV_BRIDGE_SOCK")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let dir = std::env::var("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| std::env::temp_dir());
            dir.join(format!("eav-bridge-{}.sock", users_uid()))
        });
    eprintln!("connecting to {sock:?}");

    let client = BridgeClient::connect(&sock).await?;

    // Spawn a subscriber so events don't fill the broadcast buffer.
    let mut sub = client.subscribe();
    tokio::spawn(async move {
        while let Ok(_ev) = sub.recv().await {
            // Discard.
        }
    });

    // Pick a real task to write to.
    let tasks: serde_json::Value = client.call("read.tasks", serde_json::json!({})).await?;
    let arr = tasks.as_array().expect("tasks array");
    let target = arr
        .iter()
        .find(|t| t.get("priority").and_then(|p| p.as_str()).is_some())
        .expect("no task with priority found");
    let file = target["file"].as_str().unwrap().to_string();
    let pos = target["pos"].as_u64().unwrap();
    let priority = target["priority"].as_str().unwrap().to_string();
    eprintln!(
        "target: {} (file={} pos={} prio={})",
        target["title"].as_str().unwrap_or("?"),
        file.rsplit('/').next().unwrap_or(""),
        pos,
        priority
    );

    let n = std::env::var("N")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(50);

    let mut samples_ms: Vec<f64> = Vec::with_capacity(n);
    for _ in 0..n {
        let started = Instant::now();
        let _: serde_json::Value = client
            .call(
                "write.set-priority",
                serde_json::json!({
                    "file": file,
                    "pos": pos,
                    "priority": priority,
                }),
            )
            .await?;
        samples_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        sleep(Duration::from_millis(20)).await;
    }
    samples_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let median = samples_ms[n / 2];
    let p99 = samples_ms[(n as f64 * 0.99) as usize];
    let mean = samples_ms.iter().sum::<f64>() / n as f64;
    let max = samples_ms.last().copied().unwrap_or(0.0);
    println!(
        "set-priority (n={n}): median={median:.2}ms  mean={mean:.2}ms  p99={p99:.2}ms  max={max:.2}ms"
    );
    Ok(())
}

fn users_uid() -> u32 {
    unsafe { libc::getuid() }
}
