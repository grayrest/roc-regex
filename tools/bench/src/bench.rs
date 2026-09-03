// Rust side of the throughput comparison.
//
//   cargo run --release --bin bench -- <haystack_path> <iters>
//
// For each pattern we:
//   * time `Regex::new` once (compile latency — the axis where Roc's
//     build-time constant folding pays 0 at runtime),
//   * then loop `iters` times over `find_iter`, accumulating a checksum of
//     match spans so the loop cannot be optimised away, and time only that
//     loop (match throughput — engine vs engine).
//
// Output is one CSV line per pattern:
//   id,compile_ns,match_ns_per_iter,match_count,checksum
//
// KEEP PATTERNS IN SYNC with examples/bench.roc (same ids, same regexes).

use std::env;
use std::fs;
use std::time::Instant;

// (id, regex source). Ids are stable; the Roc bench mirrors this list.
const PATTERNS: &[(&str, &str)] = &[
    ("literal", "Holmes"),
    ("teddy_alt", "Sherlock|Holmes|Watson|Adler|Irene|Norton|Baker|John"),
    ("class_plus", "[A-Za-z]+"),
    ("bounded_num", "[0-9]{2,4}"),
    ("word_bound", r"\bthe\b"),
    ("two_words", r"\w+\s+\w+"),
    ("caps_email", r"(\w+)@(\w+)"),
    ("uni_letters", r"\p{L}+"),
    ("dotstar_lit", ".*Holmes"),
];

fn main() {
    let args: Vec<String> = env::args().collect();
    let hay_path = args.get(1).map(|s| s.as_str()).unwrap_or("testdata/bench_haystack.txt");
    let iters: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(100);

    let hay = fs::read(hay_path).expect("read haystack");

    for (id, src) in PATTERNS {
        // --- compile latency ---
        let t0 = Instant::now();
        let re = regex::bytes::Regex::new(src).expect("compile");
        let compile_ns = t0.elapsed().as_nanos();

        // --- match throughput ---
        let mut checksum: u64 = 0;
        let t1 = Instant::now();
        for _ in 0..iters {
            for m in re.find_iter(&hay) {
                checksum = checksum
                    .wrapping_add(m.start() as u64)
                    .wrapping_add(m.end() as u64);
            }
        }
        let match_ns = t1.elapsed().as_nanos();
        let per_iter = match_ns / (iters as u128);

        let count = re.find_iter(&hay).count();
        println!("{},{},{},{},{}", id, compile_ns, per_iter, count, checksum);
    }
}
