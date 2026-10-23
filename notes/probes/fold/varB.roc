app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	eng: "./engB/main.roc",
}
import pf.Stdout
import eng.Eng

re : Eng.Eng
re = Eng.compile("abc")

main! = |_args| Stdout.line!(Eng.sum(re).to_str())
