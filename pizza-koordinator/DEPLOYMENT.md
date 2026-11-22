# Pizza Koordinator: nasazeni a provoz

Tento dokument popisuje aktualni nasazeni a opakovatelny postup. Jeho prikazy
spoustejte z korene repozitare. Referencni implementaci `mvp-pizzaops` nemenime.

## Aktualni prostredi

| Nastaveni | Hodnota |
|---|---|
| Tenant | `b48accae-439a-467a-9fbf-8ad011508424` |
| Subscription | `80214fc0-7aff-43b6-bbff-cf81a36cbb10` |
| Resource group / region | `rg-jjazure-ai-pizza-apps` / Sweden Central |
| Container Apps environment | `cae-pizza-22df` |
| Container Registry | `crpizza22dfk5ihazv` |
| Orders API | `https://pizza-orders.proudflower-ac7d0444.swedencentral.azurecontainerapps.io` |
| Foundry projekt | `ai-pizza-22df-k5ihazv` / `pizza-ordering-agent` |
| Bridge | `ca-pizzakoordinator` |
| Agent identity pro Azure | `id-pizzakoordinator` |

Pouzite hodnoty instance, overene v Azure, Microsoft Graph, katalogu Microsoft 365
a v importovanem ZIPu:

| Objekt | ID / hodnota |
|---|---|
| Agent 365 blueprint app ID | `2001462b-309f-4b8e-ba8d-85c3b2dd8943` |
| Blueprint service principal ID | `543d7f98-f865-4019-9d68-d74ae77a1ad0` |
| Teams manifest ID / verze | `cc6cd254-a9a5-4212-a60d-fc494825cd4a` / `1.0.0` |
| Agentic User template ID v manifestu | `pizza-koordinator-agentic-user-template` |
| Importovana sablona v katalogu | `T_ee82cd5a-31ec-21dd-4a42-65f208b97e17` |
| Agent Identity ID | `9fac1cc6-de81-4bc2-b577-5219a157e89e` |
| Agent User ID / UPN | `5f6ae514-1e47-4f8a-95e7-07e385cc752d` / `pizzakoordinator@jjazdev.org` |
| Sponsor | `jjadmin@jjazdev.org` (`63963f49-be4b-46ca-8d95-fa33e9777a22`) |
| Bridge UAMI client ID / principal ID | `074102bf-04da-49c6-9aaa-9a2ac8addc1b` / `5ba3fa24-85f4-43ab-9b73-39ccabcfe1fa` |
| Foundry agent | `pizza-koordinator-agent`, aktivni verze `2`, model `gpt-5-mini` |
| Foundry skills | `courier-preferences`, `delivery-coordination`, `preference-change-approval`, vsechny verze `2` |

Sablona a instance jsou navazane na stejny blueprint. Bridge pouziva blueprint
jako `AzureAd__ClientId`; federovany credential
`pizzakoordinator-container-app` pouziva principal ID UAMI jako `subject`.
Aktualni Container Apps revize `ca-pizzakoordinator--0000005` je Healthy,
ma 100 % provozu a `/health` vraci HTTP 200. Uzivatel potvrdil, ze instanci vidi
v portalu. Tyto kontroly nepotvrzuji doruceni zprav ani udalosti kalendare.

Instance ma licence `AGENT_365`, `Microsoft_365_Copilot`,
`Microsoft_365_E5_(no_Teams)`, `Microsoft_Teams_Enterprise_New` a `FLOW_FREE`;
`usageLocation=CZ`. Skript nastavuje sponsora, ne managera.

## Nasazeni do existujiciho prostredi

Predpoklady: PowerShell 7.3+, Azure CLI, `azd` s rozsirenim `ai`, `a365`, .NET 10,
Python s Pillow pro ikony Teams balicku a PowerShell modul
`Microsoft.Graph.Authentication`. Prihlaseni a pozadovane opravneni musi platit
pro spravny tenant. Skripty loguji do ignorovane slozky `.local`.

Spusteni z korene repozitare:

```powershell
.\pizza-koordinator\scripts\Deploy-ExistingEnvironment.ps1
```

Orchestrator provede tyto kroky:

1. Vybere subscription `80214fc0-7aff-43b6-bbff-cf81a36cbb10` a overi Orders API.
   Pokud chybi filtr `status`, spusti `Update-OrdersApi.ps1`; tento krok sestavi
   a nasadi novy image `pizza-orders`, meni tedy existujici Azure prostredek.
2. Spusti `Deploy-PizzaKoordinator.ps1 -PrepareOnly` pro tool API a identity.
3. Spusti `Register-PizzaKoordinator.ps1`: Agent 365 blueprint, Teams messaging
   endpoint `/api/messages`, federaci bridge UAMI, consent a potrebne granty.
   Vygeneruje ZIP `.local\pizzakoordinator-agent-template-1.0.0.zip`.
4. Nasadi bridge s blueprintem a nasledne Foundry agenta, OpenAPI connection
   a tri skills pres `Deploy-FoundryAgent.ps1`.
5. Overi nasazeni pres `Verify-Deployment.ps1`; toto overeni vola Foundry agenta
   a muze spotrebovat modelove tokeny.

Orchestrator **neimportuje ZIP do Microsoft 365 a nevytvari Agent User**.
Po nasazeni:

1. Spravce importuje ZIP do Microsoft 365 admin centra a overi dostupnou sablonu.
   Pred pokracovanim musi `agentIdentityBlueprintId` v definici sablony odpovidat
   blueprint ID v `a365.generated.config.json` a hodnote `AzureAd__ClientId`
   nasazeneho bridge. Pri neshode instanci nevytvaret.
2. Pro novou instanci nejprve spustit pripravu bez zapisu:

   ```powershell
   .\pizza-koordinator\scripts\Provision-Agent365Instance.ps1 -WhatIf
   ```

   Zkontrolovat tenant, prihlaseny ucet, blueprint, UPN a dostupnost peti SKU.
   Potom spustit skript bez `-WhatIf` a potvrdit operaci. Skript podle vzoru
   `mvp-pizzaops` vytvori Agent Identity a Agent User, nastavi CZ a priradi licence.
   Neprovisionuje samostatne Teams ani mailbox; po vytvoreni overit instanci
   v katalogu a prihlaseni/komunikaci v Teams zvlast.
3. Zkontrolovat v Graphu, ze `agentIdentityBlueprintId` identity odpovida blueprintu
   a `identityParentId` uzivatele odpovida ID identity. V Microsoft 365 admin centru
   otevrit **Agents → Pizza Koordinator → Instances**.

Aktualni instance uz existuje. Opakovane importovani nebo provisioning muze vytvorit
nechtenou instanci; pred jakymkoli opakovanim nejprve zkontrolovat Graph i portal.
Nesmazavat ani neprepisovat `.local\agent365\instance.pizzakoordinator.json` nebo
`a365.generated.config.json`; obsahuji vazbu na existujici objekty a konfiguraci.

## Overeni a udrzba

Rychle read-only overeni bridge a neautorizovaneho pristupu k tool API:

```powershell
.\pizza-koordinator\scripts\Verify-Deployment.ps1
```

Skript navic overi Foundry agenta a provede jeho read-only tool smoke test.
Pro testy C#:

```powershell
dotnet test .\pizza-koordinator\PizzaKoordinator.slnx
```

`Update-BridgeImage.ps1` meni pouze image existujiciho bridge a vyzaduje digest
ze stejneho ACR repository:

```powershell
.\pizza-koordinator\scripts\Update-BridgeImage.ps1 `
    -Image 'crpizza22dfk5ihazv.azurecr.io/pizzakoordinator-api@sha256:<digest>' -WhatIf
```

Po kontrole opakovat bez `-WhatIf` a potvrdit. Neprovadet soubezne s aktualizaci
konfigurace bridge.

## Chovani a provozni omezeni

- Orders API se dotazuje kazdych 30 sekund. Kuryrum se po 3 minutach bez reakce
  posle urgence; nejvyse pet urgenci.
- Stav koordinace je v pameti a bridge ma bezet jako jedna replika. Po restartu
  je potreba znovu navazat kanal zpravou `@Pizza Koordinator ahoj`.
- Pro spravu preferenci, rezervaci kalendare a dokonceni rozvozu jsou nutne skutecne
  UPN/object ID kuryrskych uctu a overeni prav k jejich Teams a kalendarum.
- Zmena preference se projevi az po schvaleni adminem; schvaleni overuje bridge
  podle Entra object ID `63963f49-be4b-46ca-8d95-fa33e9777a22`.
- `mvp-pizzaops` je samostatny funkcni vzor. Jeho kod ani nasazeni tento postup nemeni.
