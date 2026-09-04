// Deterministic haystack generator. Both the Rust and Roc benches read the
// exact same bytes, so the two engines are timed on identical work.
//
//   cargo run --release --bin gen -- <out_path> <approx_bytes>
//
// The text is drawn from a fixed word bank chosen so the benchmark patterns
// (literals, alternations, word boundaries, digits, emails, Greek letters)
// all have real work to do. A tiny LCG keeps it reproducible with no deps.

use std::env;
use std::fs;

const WORDS: &[&str] = &[
    "the", "and", "said", "that", "with", "this", "from", "have", "which",
    "Sherlock", "Holmes", "Watson", "Baker", "Adler", "Irene", "Norton", "John",
    "street", "matter", "little", "should", "morning", "window", "singular",
    "upon", "into", "would", "there", "before", "friend", "case", "very",
];

// Occasional tokens that exercise the digit / email / Unicode patterns.
const NUMBERS: &[&str] = &["1895", "221", "42", "1888", "7", "300", "17"];
const EMAILS: &[&str] = &["holmes@baker", "watson@london", "irene@warsaw"];
const GREEK: &[&str] = &["αβγδε", "ωμλ", "παράδειγμα", "λόγος"];

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        // Numerical Recipes constants.
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn pick<'a>(&mut self, xs: &[&'a str]) -> &'a str {
        xs[(self.next() as usize) % xs.len()]
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let out = args.get(1).map(|s| s.as_str()).unwrap_or("testdata/bench_haystack.txt");
    let target: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(65536);

    let mut rng = Lcg(0x9E3779B97F4A7C15);
    let mut buf = String::with_capacity(target + 64);
    let mut words_on_line = 0u32;
    let mut ntok = 0u64;

    while buf.len() < target {
        let r = rng.next() % 100; // rolled every token, so injecting below keeps
        ntok += 1; //                the RNG sequence (and dense-word counts) stable
        // A deliberately RARE literal for the sparse-prefilter bench row: not in
        // the word bank, injected ~every 700 tokens (~tens of occurrences), and
        // its "Mor" fingerprint doesn't collide with lowercase "morning".
        let tok: String = if ntok % 700 == 0 {
            "Moriarty".to_string()
        } else if r < 4 {
            rng.pick(NUMBERS).to_string()
        } else if r < 6 {
            rng.pick(EMAILS).to_string()
        } else if r < 8 {
            rng.pick(GREEK).to_string()
        } else {
            rng.pick(WORDS).to_string()
        };
        buf.push_str(&tok);
        words_on_line += 1;
        // Break into lines of ~12 tokens so `.` (no newline) and `\b`/`^`
        // anchors behave like real prose.
        if words_on_line >= 12 {
            buf.push('\n');
            words_on_line = 0;
        } else {
            buf.push(' ');
        }
    }

    fs::write(out, buf.as_bytes()).expect("write haystack");
    eprintln!("wrote {} bytes to {}", buf.len(), out);
}
