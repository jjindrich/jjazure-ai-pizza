namespace PizzaKoordinator.Worker;

public static class TextDiff
{
    /// <summary>Line diff ("- " removed, "+ " added) built from the longest common subsequence.</summary>
    public static string Lines(string before, string after)
    {
        var a = Split(before);
        var b = Split(after);
        var lcs = new int[a.Length + 1, b.Length + 1];
        for (var i = a.Length - 1; i >= 0; i--)
            for (var j = b.Length - 1; j >= 0; j--)
                lcs[i, j] = a[i] == b[j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var output = new List<string>();
        int x = 0, y = 0;
        while (x < a.Length || y < b.Length)
        {
            if (x < a.Length && y < b.Length && a[x] == b[y]) { x++; y++; }
            else if (y < b.Length && (x == a.Length || lcs[x, y + 1] >= lcs[x + 1, y])) output.Add("+ " + b[y++]);
            else output.Add("- " + a[x++]);
        }
        return string.Join('\n', output);
    }

    private static string[] Split(string text) =>
        text.ReplaceLineEndings("\n").TrimEnd('\n').Split('\n').Select(line => line.TrimEnd()).ToArray();
}
