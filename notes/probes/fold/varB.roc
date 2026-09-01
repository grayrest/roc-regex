app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	eng: "./engB/main.roc",
}
import pf.Stdout
import eng.Eng

re : Eng.Eng
re = Eng.compile("abc")

main! = |_args| Stdout.line!(Eng.sum(re).to_str())
