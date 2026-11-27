# Build context: repository root (the project references src/Pizza.Contracts).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY src/Pizza.Contracts/ src/Pizza.Contracts/
COPY pizza-koordinator/src/PizzaKoordinator.Worker/ pizza-koordinator/src/PizzaKoordinator.Worker/
RUN dotnet publish pizza-koordinator/src/PizzaKoordinator.Worker/PizzaKoordinator.Worker.csproj -c Release -o /publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
COPY --from=build /publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "PizzaKoordinator.Worker.dll"]
