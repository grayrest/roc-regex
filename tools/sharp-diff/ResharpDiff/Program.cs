// The RE# side of the differential (plan S2.3): read [{pat, hay}] JSON from the
// file named by argv[0], answer with RE#'s Matches for each as UTF-16 [start,end)
// pairs, or the exception message when RE# rejects the pattern. Also RE#'s
// FirstEnd/LongestEnd, the anchored end finders (-1 = no match).
using System.Text.Json;
using System.Text.Json.Serialization;

var input = JsonSerializer.Deserialize<List<Case>>(File.ReadAllText(args[0]))!;
var results = new List<Result>();
foreach (var c in input)
{
    try
    {
        var re = new Resharp.Regex(c.pat);
        var ms = re.Matches(c.hay);
        var spans = new List<int[]>();
        foreach (var m in ms) spans.Add(new[] { m.Index, m.Index + m.Length });
        results.Add(new Result(c.pat, c.hay, true, "", spans, re.FirstEnd(c.hay), re.LongestEnd(c.hay)));
    }
    catch (Exception e)
    {
        results.Add(new Result(c.pat, c.hay, false, e.GetType().Name + ": " + e.Message, new List<int[]>(), -1, -1));
    }
}
Console.Out.Write(JsonSerializer.Serialize(results));

record Case(string pat, string hay);
record Result(string pat, string hay, bool ok, string err, List<int[]> matches, int firstEnd, int longestEnd);
