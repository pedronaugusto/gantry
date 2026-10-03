//! syn parses a whole file into items; `use` items are what gantry's Rust
//! recovery lists. Same output rows as bench/ops.
use std::time::{Duration, Instant};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert!(args.len() == 3 && args[1] == "imports/rust", "usage: alt-rust imports/rust <file>");
    let source = std::fs::read_to_string(&args[2]).expect("fixture");
    let op = || -> usize {
        let file = syn::parse_file(&source).expect("valid Rust");
        file.items.iter().filter(|item| matches!(item, syn::Item::Use(_))).count()
    };
    let row = |metric: &str, value: String, unit: &str| println!("syn\timports/rust\t{metric}\t{value}\t{unit}");
    let mut count = op();
    if std::env::var_os("BENCH_SMOKE").is_some() {
        row("ns_per_op", "0".into(), "ns");
    } else {
        let (mut iterations, start) = (0u64, Instant::now());
        while iterations < 3 || start.elapsed() < Duration::from_millis(200) {
            count = op();
            iterations += 1;
        }
        row("ns_per_op", format!("{:.3}", start.elapsed().as_nanos() as f64 / iterations as f64), "ns");
        row("iterations", iterations.to_string(), "iterations");
    }
    row("source", source.len().to_string(), "bytes");
    row("imports", count.to_string(), "count");
}
