using System.Reflection;

namespace PizzaOps.Tests;

public sealed class TeamsRuntimeDependenciesTests
{
    [Fact]
    public void IncludesTeamsJwtValidatorAssembly()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Microsoft.IdentityModel.Validators.dll");
        Assert.True(File.Exists(path), $"Missing runtime dependency: {path}");
        var assembly = AssemblyName.GetAssemblyName(path);
        Assert.Equal(new Version(8, 23, 0, 0), assembly.Version);
    }
}
