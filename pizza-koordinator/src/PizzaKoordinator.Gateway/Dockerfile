# Build context: repository root (same as the Worker image).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY pizza-koordinator/src/PizzaKoordinator.Gateway/ pizza-koordinator/src/PizzaKoordinator.Gateway/
RUN dotnet publish pizza-koordinator/src/PizzaKoordinator.Gateway/PizzaKoordinator.Gateway.csproj -c Release -o /publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
COPY --from=build /publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "PizzaKoordinator.Gateway.dll"]
