// The RE# side of the differential (plan S2.3): read [{pat, hay}] JSON from the
// file named by argv[0], answer with RE#'s Matches for each as UTF-16 [start,end)
// pairs, or the exception message when RE# rejects the pattern.
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
        results.Add(new Result(c.pat, c.hay, true, "", spans));
    }
    catch (Exception e)
    {
        results.Add(new Result(c.pat, c.hay, false, e.GetType().Name + ": " + e.Message, new List<int[]>()));
    }
}
Console.Out.Write(JsonSerializer.Serialize(results));

record Case(string pat, string hay);
record Result(string pat, string hay, bool ok, string err, List<int[]> matches);
