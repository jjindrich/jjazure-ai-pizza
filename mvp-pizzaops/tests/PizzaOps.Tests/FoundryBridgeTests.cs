using System.Net;
using System.Text;
using System.Text.Json;
using Azure.AI.Extensions.OpenAI;
using Azure.Core;
using OpenAI.Responses;
using System.ClientModel.Primitives;

namespace PizzaOps.Tests;

public sealed class FoundryBridgeTests
{
    [Fact]
    public async Task SendsAgentInputAsPostToResponsesEndpoint()
    {
#pragma warning disable OPENAI001
        HttpMethod? method = null;
        Uri? uri = null;
        string? body = null;
        using var handler = new StubHttpMessageHandler(async (request, cancellationToken) =>
        {
            method = request.Method;
            uri = request.RequestUri;
            body = request.Content is null
                ? ""
                : await request.Content.ReadAsStringAsync(cancellationToken);

            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """
                    {
                      "id": "resp-123",
                      "object": "response",
                      "created_at": 1,
                      "status": "completed",
                      "model": "test-model",
                      "output": [{
                        "id": "msg-123",
                        "type": "message",
                        "status": "completed",
                        "role": "assistant",
                        "content": [{
                          "type": "output_text",
                          "text": "Ahoj! Umím pomoci s plánováním.",
                          "annotations": []
                        }]
                      }]
                    }
                    """,
                    Encoding.UTF8,
                    "application/json")
            };
        });
        using var httpClient = new HttpClient(handler);

        var clientOptions = new ProjectOpenAIClientOptions
        {
            ApiVersion = "v1",
            Transport = new HttpClientPipelineTransport(httpClient)
        };
        var projectClient = new ProjectOpenAIClient(
            new Uri("https://foundry.example/api/projects/pizzaops"),
            new TestTokenCredential(),
            clientOptions);
        var responseOptions = new ProjectOpenAIClientOptions
        {
            ApiVersion = "v1",
            Transport = new HttpClientPipelineTransport(httpClient)
        };
        var responseClient = projectClient.GetProjectResponsesClientForAgentEndpoint(
            "PizzaOps",
            "conv-123",
            responseOptions);

        await responseClient.CreateResponseAsync(
            new CreateResponseOptions
            {
                InputItems = { ResponseItem.CreateUserMessageItem("Ahoj, co umis?") }
            });

        Assert.Equal(HttpMethod.Post, method);
        Assert.Equal(
            "https://foundry.example/api/projects/pizzaops/agents/PizzaOps/endpoint/protocols/openai/responses?api-version=v1",
            uri?.AbsoluteUri);

        using var requestBody = JsonDocument.Parse(body!);
        var root = requestBody.RootElement;
        Assert.Equal(
            "Ahoj, co umis?",
            root.GetProperty("input")[0].GetProperty("content")[0].GetProperty("text").GetString());
        Assert.Equal("conv-123", root.GetProperty("conversation").GetProperty("id").GetString());
#pragma warning restore OPENAI001
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            send(request, cancellationToken);
    }

    private sealed class TestTokenCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            new("test-token", DateTimeOffset.UtcNow.AddMinutes(5));

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
