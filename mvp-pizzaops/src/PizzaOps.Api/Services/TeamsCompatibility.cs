using System.Reflection;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;

namespace PizzaOps.Api.Services;

public static class TeamsCompatibility
{
    // Teams Apps 2.2.1 publishes this API in XML docs but omits it from the binary.
    public static async Task<string> GetAgenticGraphTokenAsync(
        this TeamsBotApplication application,
        AgenticIdentity identity,
        CancellationToken cancellationToken = default)
    {
        var method = typeof(TeamsBotApplication).GetMethod(
            "GetAgenticGraphTokenAsync",
            BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null,
            types: [typeof(AgenticIdentity), typeof(CancellationToken)],
            modifiers: null)
            ?? throw new MissingMethodException("The Teams SDK no longer exposes Agentic User Graph token acquisition.");
        var task = (Task<string?>)method.Invoke(application, [identity, cancellationToken])!;
        return await task ?? throw new InvalidOperationException(
            "The Teams SDK could not acquire an Agentic User Graph token.");
    }
}
