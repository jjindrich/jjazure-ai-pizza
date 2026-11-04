FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
COPY ./container-publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "Pizza.Web.dll"]
