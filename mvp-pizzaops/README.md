# PizzaOps MVP

Isolated reference implementation for the PizzaOps autonomous Microsoft 365
teammate. The main reasoning runtime is a Microsoft Foundry Prompt Agent with
the managed Microsoft Copilot harness. `src/PizzaOps.Api` is intentionally only
the Teams/Agentic User bridge, Graph calendar adapter, durable tool API, and
Service Bus continuation worker.

- [Architecture](docs/pizzaops-architecture.md)
- [Deployment](docs/pizzaops-deployment.md)
- [Testing](docs/pizzaops-testing.md)
- [Demo](docs/pizzaops-demo.md)
- [Identity](docs/pizzaops-identity.md)
- [Preview limitations](docs/pizzaops-preview-limitations.md)
- [Agent-template registration](docs/pizzaops-agent-template-registration.md)
- [Troubleshooting](docs/pizzaops-troubleshooting.md)

Build from this directory:

```powershell
dotnet restore PizzaOps.slnx
dotnet build PizzaOps.slnx --configuration Release --no-restore
dotnet test PizzaOps.slnx --configuration Release --no-build
python tests\pizzaops_validate.py
```

To add an Agent 365 instance after the blueprint and template are ready, see
[instance provisioning](docs/pizzaops-agent-template-registration.md#create-an-agent-365-instance).
For example:

```powershell
.\scripts\Provision-Agent365Instance.ps1 -InstanceName 'pizzaops-workshop' `
  -AgentUpn 'pizzaops-workshop@jjazdev.org' -DisplayName 'PizzaOps Workshop' `
  -MailNickname 'pizzaops-workshop' -DryRun
```

Use `scripts\Update-PizzaOpsApi.ps1` for image-only updates of the existing
private-network API. `scripts\Deploy-PizzaOps.ps1` is the broader infrastructure
bootstrap, not an image-only update. See [Deployment](docs/pizzaops-deployment.md)
for prerequisites and approval boundaries. The Teams blueprint, tenant consent,
and Agentic User activation remain administrator-controlled tenant steps.
