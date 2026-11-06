FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY tools/Pizza.SqlInitializer/ ./
RUN dotnet publish Pizza.SqlInitializer.csproj -c Release -o /publish --no-self-contained /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "Pizza.SqlInitializer.dll"]
