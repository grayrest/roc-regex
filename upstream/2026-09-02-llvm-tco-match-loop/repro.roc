app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package/main.roc",
}
import pf.Stdout
import re.Regex

# Self-contained repro for the LLVM-backend tail-call miss described in
# 2026-09-02-llvm-tco-match-loop.md.
#
# NOTE: this reproduces against the PRE-FIX Regex.all_caps (recursive form).
# On current HEAD all_caps is an explicit `while` loop and does not overflow;
# to reproduce, check out the parent of the fix commit, or replace all_caps
# with the recursive version quoted in the write-up.
#
#   roc build --no-cache --opt=speed upstream/2026-09-02-llvm-tco-match-loop/repro.roc && ./repro
#     -> SIGBUS (exit 138)
#   roc build --no-cache --opt=dev   upstream/2026-09-02-llvm-tco-match-loop/repro.roc && ./repro
#     -> prints "matches: 100000"
main! = |_a| {
	# 100k "a " pairs; [A-Za-z]+ matches each single 'a' across the spaces,
	# so find_all reports 100000 matches and its match loop iterates 100000x.
	var hay = []
	var i = 0
	while i < 100_000 {
		hay = List.append(List.append(hay, 97), 32)
		i = i + 1
	}
	n = List.len(Regex.find_all(Regex.unwrap(Regex.compile("[A-Za-z]+")), hay))
	Stdout.line!("matches: ${n.to_str()}")
}
