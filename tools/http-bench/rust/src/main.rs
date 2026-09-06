// The Rust side of the HTTP parse benchmark (H10): httparse for framing,
// matchit for routing -- the hand-tuned parser the Roc claim is measured
// against, and the router package-http's syntax comes from.
//
// The task, identical on both sides: for each request, frame it (method,
// target, version), select the route and bind its parameters, and read three
// named headers. The checksum is the sum of every piece's length plus the
// matched route's index, so a divergence in ANY piece changes it.
use std::time::Instant;

const LOOKUPS: [&str; 3] = ["content-length", "host", "x-request-id"];

fn routes() -> matchit::Router<usize> {
    let mut r = matchit::Router::new();
    // KEEP IN SYNC with examples/http_bench.roc
    for (i, p) in [
        "/", "/health", "/users", "/users/{id}", "/users/{id}/posts",
        "/users/{id}/posts/{slug}", "/user_profiles/{id}",
        "/images/img{id}.png", "/static/{*rest}",
    ]
    .iter()
    .enumerate()
    {
        r.insert(*p, i).unwrap();
    }
    r
}

// split the fixture into requests at each `\r\n\r\n`
fn split(buf: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i + 3 < buf.len() {
        if &buf[i..i + 4] == b"\r\n\r\n" {
            out.push(&buf[start..i + 4]);
            start = i + 4;
            i += 4;
        } else {
            i += 1;
        }
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let iters: u32 = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(200);
    let buf = std::fs::read(path).unwrap();
    let reqs = split(&buf);
    let router = routes();

    let mut checksum: u64 = 0;
    let t0 = Instant::now();
    for _ in 0..iters {
        checksum = 0;
        for raw in &reqs {
            let mut headers = [httparse::EMPTY_HEADER; 32];
            let mut req = httparse::Request::new(&mut headers);
            if req.parse(raw).is_err() {
                continue;
            }
            let method = req.method.unwrap();
            let target = req.path.unwrap();
            checksum += method.len() as u64 + target.len() as u64 + req.version.unwrap() as u64;
            // route on the path, ignoring any query string
            let path_only = target.split('?').next().unwrap();
            if let Ok(m) = router.at(path_only) {
                checksum += *m.value as u64;
                for (_, v) in m.params.iter() {
                    checksum += v.len() as u64;
                }
            }
            for want in LOOKUPS {
                for h in req.headers.iter() {
                    if h.name.eq_ignore_ascii_case(want) {
                        checksum += h.value.len() as u64;
                        break;
                    }
                }
            }
        }
    }
    let ns = t0.elapsed().as_nanos() / iters as u128;
    println!("rust,{},{},{}", ns, reqs.len(), checksum);
}
