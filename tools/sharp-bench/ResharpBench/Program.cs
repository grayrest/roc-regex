// Times the ORIGINAL RE# on the same patterns and haystack as tools/bench, so
// the Roc port can be compared against the implementation it ports.
//
//   ResharpBench <haystack> [iters]
//
// KEEP PATTERNS IN SYNC with tools/bench/src/bench.rs, examples/bench.roc and
// examples/bench_sharp.roc: same ids, same regexes.
//
// Method, matching the other harnesses: the regex is constructed once, before
// the loop, and construction is reported separately because RE# compiles at
// runtime while Roc folds at build time. Each iteration is timed on its own and
// the MINIMUM is kept, since noise only ever inflates a run. A warmup phase runs
// first and is discarded, which matters far more here than for the AOT engines:
// .NET has to JIT the engine and build its lazy DFA on the first pass. The
// warmup covers a literal, an alternation, a class, a word border and a
// dot-star so that the CONSTRUCTION timings below are not measuring JIT either.
using System.Diagnostics;

var hayPath = args.Length > 0 ? args[0] : "testdata/bench_haystack.txt";
var iters = args.Length > 1 ? int.Parse(args[1]) : 20;
var hay = File.ReadAllText(hayPath);

var patterns = new (string id, string src)[]
{
    ("literal_dense", "Holmes"),
    ("literal_sparse", "Moriarty"),
    ("teddy_alt", "Sherlock|Holmes|Watson|Adler|Irene|Norton|Baker|John"),
    ("class_plus", "[A-Za-z]+"),
    ("bounded_num", "[0-9]{2,4}"),
    ("word_bound", @"\bthe\b"),
    ("two_words", @"\w+\s+\w+"),
    ("caps_email", @"(\w+)@(\w+)"),
    ("uni_letters", @"\p{L}+"),
    ("dotstar_lit", ".*Holmes"),
};

static long NsPerTick() => 1_000_000_000L / Stopwatch.Frequency;

// JIT the construction and matching paths before anything is timed, or the
// first pattern's "compile" figure is really the cost of warming up .NET
// (measured at 102 ms against 1.8 ms for the next pattern).
foreach (var w in new[] { "a", "abcdef", "a|bc|def", "[a-z]+", @"\bx\b", @"\w+\s+\w+", ".*abc" })
{
    var warm = new Resharp.Regex(w);
    foreach (var _ in warm.Matches("a bc def abc xyz 12")) { }
}

Console.WriteLine("id,compile_ns,match_ns_per_iter,match_count,checksum");
foreach (var (id, src) in patterns)
{
    try
    {
        var sw = Stopwatch.StartNew();
        var re = new Resharp.Regex(src);
        sw.Stop();
        var compileNs = sw.ElapsedTicks * NsPerTick();

        // warmup: JIT the engine and let the lazy DFA fill before anything is timed
        long warmCount = 0;
        for (var i = 0; i < 5; i++) warmCount += CountAndSum(re, hay).count;

        long best = long.MaxValue;
        long count = 0, checksum = 0;
        for (var i = 0; i < iters; i++)
        {
            sw.Restart();
            var r = CountAndSum(re, hay);
            sw.Stop();
            var ns = sw.ElapsedTicks * NsPerTick();
            if (ns < best) best = ns;
            count = r.count;
            checksum = r.checksum;
        }
        Console.WriteLine($"{id},{compileNs},{best},{count},{checksum}");
    }
    catch (Exception e)
    {
        Console.WriteLine($"{id},0,0,-1,0  # rejected: {e.GetType().Name}: {e.Message.Split('\n')[0]}");
    }
}

// Sum the span endpoints so the match loop has an observable result, exactly as
// the Roc and Rust harnesses do.
static (long count, long checksum) CountAndSum(Resharp.Regex re, string hay)
{
    long n = 0, sum = 0;
    foreach (var m in re.Matches(hay)) { n++; sum += m.Index + (m.Index + m.Length); }
    return (n, sum);
}
