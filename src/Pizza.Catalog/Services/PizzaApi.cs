using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Mvc;
using Pizza.Catalog.Data;
using Pizza.Contracts;

namespace Pizza.Catalog.Services;

public static class PizzaApi
{
    public static void MapPizzaApi(this WebApplication app)
    {
        var catalog = app.MapGroup("/api/catalog").WithTags("Pizza catalog").RequireRateLimiting("pizza-api");
        catalog.MapGet("/pizzas", async (PizzaCatalogService service, CancellationToken token) =>
            Results.Ok(await service.GetAllAsync(token)));
        catalog.MapGet("/pizzas/{id:guid}", async Task<Results<Ok<PizzaItem>, NotFound>> (
            Guid id, PizzaCatalogService service, CancellationToken token) =>
        {
            var pizza = await service.GetAsync(id, token);
            return pizza is null ? TypedResults.NotFound() : TypedResults.Ok(pizza);
        });
        catalog.MapPost("/pizzas", async Task<Results<Created<PizzaItem>, ValidationProblem>> (
            PizzaUpsertRequest request, PizzaCatalogService service, CancellationToken token) =>
        {
            try
            {
                var pizza = await service.CreateAsync(request, token);
                return TypedResults.Created($"/api/catalog/pizzas/{pizza.Id}", pizza);
            }
            catch (CatalogValidationException exception)
            {
                return TypedResults.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["request"] = [exception.Message]
                });
            }
        });
        catalog.MapPut("/pizzas/{id:guid}", async (
            Guid id, PizzaUpsertRequest request, PizzaCatalogService service, CancellationToken token) =>
        {
            try
            {
                var pizza = await service.UpdateAsync(id, request, token);
                return pizza is null ? Results.NotFound() : Results.Ok(pizza);
            }
            catch (CatalogValidationException exception)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["request"] = [exception.Message]
                });
            }
        });
        catalog.MapDelete("/pizzas/{id:guid}", async (
            Guid id, PizzaCatalogService service, CancellationToken token) =>
                await service.DeleteAsync(id, token) ? Results.NoContent() : Results.NotFound());
        catalog.MapPost("/pizzas/{id:guid}/image", async (
            Guid id,
            IFormFile file,
            PizzaCatalogService service,
            IPizzaImageStore images,
            CancellationToken token) =>
        {
            if (file.Length is <= 0 or > 5 * 1024 * 1024)
            {
                return Results.BadRequest(new { error = "Image must be between 1 byte and 5 MB." });
            }

            if (await service.GetAsync(id, token) is null)
            {
                return Results.NotFound();
            }

            try
            {
                _ = ImageFilePolicy.GetExtension(file.ContentType);
                await using var source = file.OpenReadStream();
                var bytes = await ImageFilePolicy.ReadValidatedAsync(source, file.ContentType, token);
                await using var stream = new MemoryStream(bytes, writable: false);
                var key = await images.SaveAsync(stream, file.ContentType, token);
                var updated = await service.SetImageAsync(id, $"/api/catalog/images/{key}", token);
                return updated is null ? Results.NotFound() : Results.Ok(updated);
            }
            catch (InvalidDataException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        }).DisableAntiforgery().WithMetadata(new RequestSizeLimitAttribute(5 * 1024 * 1024 + 64 * 1024));
        catalog.MapGet("/images/{key}", async (
            string key, IPizzaImageStore images, CancellationToken token) =>
        {
            if (Path.GetFileName(key) != key)
            {
                return Results.BadRequest();
            }

            var content = await images.OpenReadAsync(key, token);
            return content is null
                ? Results.NotFound()
                : Results.Stream(content.Stream, content.ContentType);
        });

    }
}
