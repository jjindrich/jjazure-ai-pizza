FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY src/Pizza.Contracts/ src/Pizza.Contracts/
COPY src/Shared/ src/Shared/
COPY src/Pizza.Catalog/ src/Pizza.Catalog/
RUN dotnet publish src/Pizza.Catalog/Pizza.Catalog.csproj -c Release -o /publish --no-self-contained /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
COPY --from=build /publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "Pizza.Catalog.dll"]
