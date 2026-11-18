app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	eng: "./engB/main.roc",
}
import pf.Stdout
import eng.Eng

re : Eng.Eng
re = Eng.compile("abc")

main! = |_args| Stdout.line!(Eng.sum(re).to_str())
