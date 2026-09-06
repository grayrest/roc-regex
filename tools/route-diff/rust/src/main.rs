// The matchit side of the router differential: `Rtrie` is a from-scratch port
// of matchit 0.8's radix trie, so its answers are checked against the original.
//
// Reads a route table and a path list from the files named by argv, and for
// each path prints the matched route's index and its bound parameters, or `-`.
use std::io::Read;

fn main() {
    let mut a = std::env::args().skip(1);
    let routes_path = a.next().unwrap();
    let paths_path = a.next().unwrap();
    let mut s = String::new();
    std::fs::File::open(&routes_path).unwrap().read_to_string(&mut s).unwrap();
    let routes: Vec<&str> = s.lines().filter(|l| !l.is_empty()).collect();
    let mut p = String::new();
    std::fs::File::open(&paths_path).unwrap().read_to_string(&mut p).unwrap();

    // report a route matchit itself rejects, so the Roc side can expect the same
    let mut router = matchit::Router::new();
    for (i, r) in routes.iter().enumerate() {
        if let Err(e) = router.insert(*r, i) {
            println!("INSERT_ERR\t{}\t{}", r, e);
            return;
        }
    }
    for path in p.lines() {
        if path.is_empty() {
            continue;
        }
        match router.at(path) {
            Ok(m) => {
                let mut ps: Vec<String> = m.params.iter().map(|(k, v)| format!("{}={}", k, v)).collect();
                ps.sort();
                println!("{}\t{}\t{}", path, m.value, ps.join(","));
            }
            Err(_) => println!("{}\t-\t", path),
        }
    }
}
