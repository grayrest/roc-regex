app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "/Users/grayrest/dev/roc/regex/.claude/worktrees/resharp-regex-design-review-60cff0/package-sharp/main.roc",
}
import pf.Stdout
import re.Sharp

Case : { pat : Str, hay : Str }
cases : List(Case)
cases = [
	{ pat: "(?<=6|8\\(.*).*&(?<=6|8\\(|4|8|0\\().*&~(.*\\)\\:.*)&\\w.*&.*\\w&.*(?=.*\\)\\:)&.*(?=\\)\\:|\\)\\:)", hay: "\nJan 12 06:26:19: ACCEPT service http from 119.63.193.196 to firewall(pub-nic), prefix: \"none\" (in: eth0 119.63.193.196(5c:0a:5b:63:4a:82):4399 -> 140.105.63.164(50:06:04:92:53:44):80 TCP flags: ****S* len:60 ttl:32)\nJan 12 06:26:20: ACCEPT service dns from 140.105.48.16 to firewall(pub-nic-dns), prefix: \"none\" (in: eth0 140.105.48.16(00:21:dd:bc:95:44):4263 -> 140.105.63.158(00:14:31:83:c6:8d):53 UDP len:76 ttl:62)\nJan 12 06:27:09: DROP service 68->67(udp) from 216.34.211.83 to 216.34.253.94, prefix: \"spoof iana-0/8\" (in: eth0 213.92.153.78(00:1f:d6:19:0a:80):68 -> 69.43.177.110(00:30:fe:fd:d6:51):67 UDP len:576 ttl:64)" },
]

run : Case, Str -> Str
run = |c0, filler| {
	c = { pat: Str.concat(c0.pat, filler), hay: Str.concat(c0.hay, filler) }
	match Sharp.compile(c.pat) {
		Err(e) => "ERR ${Sharp.err_str(e)}"
		Ok(re) => "rev: ${Sharp.show_rev(re)}"
	}
}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	results = List.map(cases, |c| run(c, filler))
	Stdout.line!(Str.join_with(results, "\n"))
}
