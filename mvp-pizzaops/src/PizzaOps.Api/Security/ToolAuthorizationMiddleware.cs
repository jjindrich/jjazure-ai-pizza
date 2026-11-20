using Microsoft.AspNetCore.Authentication;

namespace PizzaOps.Api.Security;

public sealed class ToolAuthorizationMiddleware(IToolAuthorization authorization) : IMiddleware
{
    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        if (context.GetEndpoint()?.Metadata.GetMetadata<RequireToolAuthorizationAttribute>() is not null)
        {
            if (!authorization.IsAuthorized(context.User))
            {
                var authentication = await context.AuthenticateAsync("PizzaOpsTools");
                if (authentication.Succeeded)
                    context.User = authentication.Principal;
                if (!authorization.IsAuthorized(context.User))
                {
                    context.Response.StatusCode = StatusCodes.Status403Forbidden;
                    await context.Response.WriteAsJsonAsync(new
                    {
                        error = "forbidden",
                        message = "The caller is not authorized for PizzaOps tools."
                    });
                    return;
                }
            }
        }
        await next(context);
    }
}
