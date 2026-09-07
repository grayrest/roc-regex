app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../package/main.roc",
}
import pf.Stdout
import re.Regex

# A literal pattern is compiled while the program builds, and the finished
# automaton is stored in the binary. A pattern that does not parse fails the
# build with a message and a caret under the offending character.
email : Regex.Pattern
email = Regex.build("\\w+@\\w+\\.\\w+")

# `&` is intersection: a line that mentions both names, in either order.
both : Regex.Pattern
both = Regex.build(".*Holmes.*&.*Watson.*")

main! = |_args| {
	text = "Watson wrote to holmes@baker.st; Holmes replied from 221b@baker.st."
	bytes = Str.to_utf8(text)

	# Every non-overlapping match, as half-open byte offsets into `bytes`.
	addresses = List.map(Regex.find_all(email, bytes), |sp| Str.from_utf8_lossy(List.sublist(bytes, { start: sp.start, len: sp.end - sp.start })))
	Stdout.line!(Str.join_with(addresses, ", "))?

	# `$0` in the replacement is the matched text.
	Stdout.line!(Regex.replace_all_str(email, text, "<$0>"))?

	Stdout.line!(if Regex.is_match_str(both, text) { "mentions both" } else { "does not mention both" })?
	Ok({})
}
