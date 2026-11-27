using YamlDotNet.RepresentationModel;

namespace PizzaKoordinator.Tests;

public sealed class FoundryManifestTests
{
    [Fact]
    public void Meeting_location_schema_has_no_unexpected_yaml_keys()
    {
        using var reader = File.OpenText(Path.Combine(AppContext.BaseDirectory, "Foundry", "azure.yaml"));
        var document = new YamlStream();
        document.Load(reader);

        var service = Get(Get(document.Documents[0].RootNode, "services"), "pizza-koordinator-agent");
        var tools = Assert.IsType<YamlSequenceNode>(Get(service, "tools"));
        var openApi = Assert.Single(tools.Children, tool =>
            Get(tool, "type") is YamlScalarNode { Value: "openapi" });
        var spec = Get(Get(openApi, "openapi"), "spec");
        var meeting = Get(Get(Get(spec, "paths"), "/v1/meetings"), "post");
        var schema = Get(Get(Get(Get(meeting, "requestBody"), "content"), "application/json"), "schema");
        var location = Assert.IsType<YamlMappingNode>(Get(Get(schema, "properties"), "location"));

        Assert.Equal(["description", "type"], location.Children.Keys
            .Cast<YamlScalarNode>()
            .Select(key => key.Value)
            .OrderBy(key => key, StringComparer.Ordinal));
    }

    private static YamlNode Get(YamlNode node, string key) =>
        Assert.IsType<YamlMappingNode>(node).Children[new YamlScalarNode(key)];
}
