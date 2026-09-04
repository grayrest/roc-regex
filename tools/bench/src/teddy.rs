// Direct 128-bit Teddy throughput reference, to compare against this package's
// Teddy.scan. Uses aho-corasick's packed Teddy (the canonical 128-bit Teddy,
// same algorithm as package/Teddy.roc), forced to 128-bit (not the 256-bit AVX2
// "fat" variant, which Roc can't express — it has only 128-bit vectors).
//
//   teddy <haystack> [iters] [literal...]
//
// Prints ns/iter and GB/s scanning the whole haystack. aho-corasick's packed
// searcher verifies exact matches; our Teddy.scan only fingerprints (a superset)
// and leaves verification to the caller, so if anything this reference does more
// work per hit — making it the right upper bound for "what the SIMD scan costs."
use std::time::Instant;
use aho_corasick::packed::Config;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let iters: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(200);
    let lits: Vec<String> = if args.len() > 3 {
        args[3..].to_vec()
    } else {
        vec!["Holmes".to_string()]
    };
    let hay = std::fs::read(path).expect("read haystack");

    let mut cfg = Config::new();
    cfg.only_teddy(true).only_teddy_256bit(Some(false)); // force 128-bit Teddy
    let mut b = cfg.builder();
    for l in &lits {
        b.add(l);
    }
    let searcher = b.build().expect("128-bit Teddy not available for these literals");

    // warm up
    let mut count = searcher.find_iter(&hay).count() as u64;
    let t0 = Instant::now();
    for _ in 0..iters {
        count = count.wrapping_add(searcher.find_iter(&hay).count() as u64);
    }
    let ns = t0.elapsed().as_nanos() as u64 / iters;
    let gbps = hay.len() as f64 / ns as f64; // bytes/ns == GB/s
    eprintln!(
        "rust 128-bit Teddy: {ns} ns/iter  {:.2} GB/s  ({} matches/iter, {} bytes, lits={:?})",
        gbps,
        count / iters.max(1),
        hay.len(),
        lits
    );
}
