app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import re.Sharp
import re.Dfa
import re.Rlit
import re.Trie
import re.Utf8
import re.Bset

rx : Sharp.T
rx = Sharp.unwrap(Sharp.compile("(\\w+)@(\\w+)"))

# B: no hoisting, e.* inline
cp_b : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64), Bool -> { s : U32, acc : List(U64) }
cp_b = |e, t, pf, hay, pos0, s0, acc0, skip| {
	start_state = e.s_rev_ts
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = pf.state
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = Dfa.set_null_fast(e, s, acc, hay, pos)
			}
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if skip and (List.get(e.skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(e.skip_lo, s.to_u64(), b) {
				np =
					match Bset.rfind(hay, e.skip_lo, s.to_u64(), pos - 1) {
						Ok(p) => p + 1
						Err(_) => 0
					}
				if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
					acc = Dfa.set_null_range(e, s, acc, hay, np, pos - 1)
				}
				pos = np
			} else {
				if b < 0x80 {
					s = List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
					pos = pos - 1
				} else {
					d = Utf8.decode_rev(hay, pos)
					cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
					s = List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead
					pos = d.cs
				}
				k = List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull
				if k == Dfa.nk_current {
					acc = List.append(acc, pos)
				} else if k != Dfa.nk_notnull {
					acc = Dfa.set_null_fast(e, s, acc, hay, pos)
				}
			}
		}
	}
	{ s, acc }
}

# C: hoisted lists, pf.state hoisted to a scalar
cp_c : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64), Bool -> { s : U32, acc : List(U64) }
cp_c = |e, t, pf, hay, pos0, s0, acc0, skip| {
	at = e.atable
	nks = e.st_nk
	skip_ok = e.skip_ok
	skip_lo = e.skip_lo
	table = e.table
	nmt = e.nmt.to_u64()
	start_state = e.s_rev_ts
	land = pf.state
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = land
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(nks, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = Dfa.set_null_fast(e, s, acc, hay, pos)
			}
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if skip and (List.get(skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(skip_lo, s.to_u64(), b) {
				np =
					match Bset.rfind(hay, skip_lo, s.to_u64(), pos - 1) {
						Ok(p) => p + 1
						Err(_) => 0
					}
				if (List.get(nks, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
					acc = Dfa.set_null_range(e, s, acc, hay, np, pos - 1)
				}
				pos = np
			} else {
				if b < 0x80 {
					s = List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
					pos = pos - 1
				} else {
					d = Utf8.decode_rev(hay, pos)
					cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
					s = List.get(table, s.to_u64() * nmt + cls.to_u64()) ?? Dfa.dead
					pos = d.cs
				}
				k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
				if k == Dfa.nk_current {
					acc = List.append(acc, pos)
				} else if k != Dfa.nk_notnull {
					acc = Dfa.set_null_fast(e, s, acc, hay, pos)
				}
			}
		}
	}
	{ s, acc }
}


count_hits : List(U8), Trie.T, Rlit.Prefix, U64, U64 -> U64
count_hits = |hay, t, pf, pos, n|
	if pos == 0 { n } else {
		match Rlit.rfind_sets(hay, t, pf, pos) {
			Ok(st) => count_hits(hay, t, pf, st, n + 1)
			Err(_) => n
		}
	}

# B with a plain append instead of set_null_fast
cp_b2 : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64) -> { s : U32, acc : List(U64) }
cp_b2 = |e, t, pf, hay, pos0, s0, acc0| {
	start_state = e.s_rev_ts
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = pf.state
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if b < 0x80 {
				s = List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
				pos = pos - 1
			} else {
				d = Utf8.decode_rev(hay, pos)
				cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
				s = List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead
				pos = d.cs
			}
			k = List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull
			if k != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		}
	}
	{ s, acc }
}

# B with a plain append instead of set_null_fast
cp_b3 : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64) -> { s : U32, acc : List(U64) }
cp_b3 = |e, t, pf, hay, pos0, s0, acc0| {
	start_state = e.s_rev_ts
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = pf.state
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if b < 0x80 {
				s = List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
				pos = pos - 1
			} else {
				d = Utf8.decode_rev(hay, pos)
				cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
				s = List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead
				pos = d.cs
			}
			k = List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull
			if k == Dfa.nk_current {
				acc = List.append(acc, pos)
			} else if k != Dfa.nk_notnull {
				acc = Dfa.set_null_fast(e, s, acc, hay, pos)
			}
		}
	}
	{ s, acc }
}

# B with a plain append instead of set_null_fast
cp_b4 : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64) -> { s : U32, acc : List(U64) }
cp_b4 = |e, t, pf, hay, pos0, s0, acc0| {
	start_state = e.s_rev_ts
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = pf.state
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		} else if False and (List.get(e.skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(e.skip_lo, s.to_u64(), List.get(hay, pos - 1) ?? 0) {
			np =
				match Bset.rfind(hay, e.skip_lo, s.to_u64(), pos - 1) {
					Ok(p) => p + 1
					Err(_) => 0
				}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = Dfa.set_null_range(e, s, acc, hay, np, pos - 1)
			}
			pos = np
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if b < 0x80 {
				s = List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
				pos = pos - 1
			} else {
				d = Utf8.decode_rev(hay, pos)
				cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
				s = List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead
				pos = d.cs
			}
			k = List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull
			if k != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		}
	}
	{ s, acc }
}

# B with a plain append instead of set_null_fast
cp_b5 : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64) -> { s : U32, acc : List(U64) }
cp_b5 = |e, t, pf, hay, pos0, s0, acc0| {
	start_state = e.s_rev_ts
	var pos = pos0
	var s = s0
	var acc = acc0
	while pos > 0 {
		if s == start_state {
			match Rlit.rfind_sets(hay, t, pf, pos) {
				Ok(start) => {
					pos = start
					s = pf.state
				}
				Err(_) => {
					pos = 0
				}
			}
			if (List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull) != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		} else if False and (List.get(e.skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(e.skip_lo, s.to_u64(), List.get(hay, pos - 1) ?? 0) {
			np =
				match Bset.rfind(hay, e.skip_lo, s.to_u64(), pos - 1) {
					Ok(p) => p + 1
					Err(_) => 0
				}
			pos = np
		} else {
			b = List.get(hay, pos - 1) ?? 0
			if b < 0x80 {
				s = List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead
				pos = pos - 1
			} else {
				d = Utf8.decode_rev(hay, pos)
				cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
				s = List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead
				pos = d.cs
			}
			k = List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull
			if k != Dfa.nk_notnull {
				acc = List.append(acc, pos)
			}
		}
	}
	{ s, acc }
}

main! = |args| {
	hay = match List.last(args) { Ok(a) => Path.read_bytes!(Path.from_os_str(a))? Err(_) => [] }
	Stdout.line!("bytes=${List.len(hay).to_str()}")?
	pf = match rx.accel.init { Prefix(p) => p, NoInit => { sets: [], anchor: 0, anchor_byte: 0, state: 0 } }
	Stdout.line!("pf state=${pf.state.to_str()} sets=${List.len(pf.sets).to_str()} anchor=${pf.anchor.to_str()} byte=${pf.anchor_byte.to_str()}")?
	r1 = Rlit.rfind_sets(hay, rx.trie, pf, List.len(hay))
	Stdout.line!("1 rfind_sets once: ${match r1 { Ok(v) => v.to_str(), Err(_) => "none" }}")?
	n = count_hits(hay, rx.trie, pf, List.len(hay), 0)
	Stdout.line!("2 rfind_sets loop hits: ${n.to_str()}")?
	a3 = Dfa.set_null_fast(rx.e, 4, [], hay, 100)
	Stdout.line!("3 set_null_fast: ${List.len(a3).to_str()} nk4=${(List.get(rx.e.st_nk, 4) ?? 99).to_str()}")?
	r4 = cp_b2(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [])
	Stdout.line!("4 B2 (plain appends): ${List.len(r4.acc).to_str()}")?
	r5 = cp_b5(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [])
	Stdout.line!("4c B5 (dead skip, no range): ${List.len(r5.acc).to_str()}")?
	r4b = cp_b4(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [])
	Stdout.line!("4b B4 (dead skip branch): ${List.len(r4b.acc).to_str()}")?
	r3 = cp_b3(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [])
	Stdout.line!("4a B3 (dead set_null_fast): ${List.len(r3.acc).to_str()}")?
	rb = cp_b(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [], False)
	Stdout.line!("5 B no-hoist: ${List.len(rb.acc).to_str()}")?
	rc = cp_c(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [], False)
	Stdout.line!("6 C hoisted+land: ${List.len(rc.acc).to_str()}")?
	ra = Dfa.collect_prefix(rx.e, rx.trie, pf, hay, List.len(hay), rx.e.s_rev_ts, [], False)
	Stdout.line!("7 Dfa.collect_prefix: ${List.len(ra.acc).to_str()}")
}
