app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import re.Sharp

rx : Sharp.T
rx = Sharp.unwrap(Sharp.compile("[A-Za-z]+"))

main! = |args| {
	hay = match List.last(args) { Ok(p) => Path.read_bytes!(Path.from_os_str(p))? Err(_) => [] }
	cs = List.fold(Sharp.find_all(rx, hay), 0, |acc, sp| acc + sp.start + sp.end)
	t = rx.trie
	e = rx.e
	a = rx.a
	Stdout.line!("cs=${cs.to_str()} n_classes=${t.n_classes.to_str()} | trie lens: ascii=${List.len(t.ascii).to_str()} l1=${List.len(t.l1).to_str()} leaves=${List.len(t.leaves).to_str()} tsets=${List.len(t.set_tsets).to_str()} cuts=${List.len(t.cuts).to_str()} mt=${List.len(t.mt_of_atom).to_str()}")
}
