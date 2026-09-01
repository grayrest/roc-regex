app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.Stdout

parse : Str -> U64
parse = |s|
	if Str.is_empty(s) {
		crash "empty pattern"
	} else {
		Str.to_utf8(s).len()
	}

n : U64
n = parse("")

main! = |_args| Stdout.line!(n.to_str())
