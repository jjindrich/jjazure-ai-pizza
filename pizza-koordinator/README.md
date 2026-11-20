# PizzaKoordinator

Autonomní agent v Microsoft Teams kanálu, který hlídá nové objednávky pizzy
z Orders API a koordinuje jejich rozvoz mezi kurýry **Kuryr1**, **Kuryr2** a **Kuryr3**.
Vychází z ukázky [`mvp-pizzaops`](../mvp-pizzaops), kterou nemění.

## Jak to funguje

```
Orders API ──(poll ?status=New)──► PizzaKoordinator bridge (C#, Container App)
                                     │  ▲  OpenAPI tools (assign / complete / propose)
     Teams kanál ◄──agentic user──►  │  │
                                     ▼  │
                         Foundry Prompt Agent (Copilot harness) + skills
                         courier-preferences | delivery-coordination | preference-change-approval
```

| Požadavek | Kde je to řešené |
|---|---|
| Nová objednávka → zpráva do kanálu a výzva kurýrům | `OrderWatcher` (polling) → agent (`delivery-coordination`) → proaktivní zpráva do kanálu |
| Urgence po 3 minutách ticha | `CoordinatorState.TakeDueForUrge` (každá zpráva kurýra časovač resetuje, max 5 urgencí) |
| Přidělení → pozvánka do kalendáře + e-mail adminovi | tool `assignDelivery`: Graph `/me/events` (místo = adresa zákazníka) a `/me/sendMail` na `jjadmin@jjazdev.org` |
| „Doručeno“ → objednávka hotová | tool `completeDelivery`: posune objednávku v Orders API až do `Completed` |
| Preference kurýrů | skill [`courier-preferences`](foundry-skills/courier-preferences/SKILL.md) (zkušební data) |
| Změna preference se schválením admina | tool `proposePreferenceChange` → diff do kanálu i e-mailem → admin napíše `@PizzaKoordinator schvaluji <ID>` / `zamitam <ID>` → bridge vytvoří novou verzi skillu a novou verzi agenta |

Schválení/zamítnutí vyhodnocuje bridge deterministicky (ne LLM) a přijme ho jen od
uživatele s `AdminAadObjectId`. Dokud admin nerozhodne, skill se nemění.

Orders API dostalo filtr `GET /api/orders/?status=New` (zbytek API se nemění).

## Nasazení

Předpoklady: `az`, `azd` (s `azd ai` extension), `a365` CLI, .NET 10, PowerShell 7.3+,
existující prostředí z MVP (resource group, ACR, Container Apps environment, Foundry projekt).

```powershell
# 1) Bridge (Container App, 1 replika) – vypíše ApiUrl, ToolAudience, BridgeIdentityPrincipalId
.\pizza-koordinator\scripts\Deploy-PizzaKoordinator.ps1 -OrdersApiUrl https://<orders-api>

# 2) Foundry agent + skills + OpenAPI connection
.\pizza-koordinator\scripts\Deploy-FoundryAgent.ps1 -ProjectEndpoint <FoundryEndpoint> -ApiUrl <ApiUrl> -ApiAudience <ToolAudience>

# 3) Agent 365 blueprint (federace s identitou bridge, Calendars.ReadWrite + Mail.Send, Teams balíček)
.\pizza-koordinator\scripts\Register-PizzaKoordinator.ps1 -MessagingEndpoint <MessagingEndpoint> -BridgeIdentityPrincipalId <BridgeIdentityPrincipalId>

# 4) Bridge znovu, tentokrát s blueprintem pro Teams
.\pizza-koordinator\scripts\Deploy-PizzaKoordinator.ps1 -OrdersApiUrl https://<orders-api> -BlueprintId <blueprintId>

# 5) Instance agentic usera (znovupoužitý MVP skript)
.\mvp-pizzaops\scripts\Provision-Agent365Instance.ps1 -BlueprintId <blueprintId> -InstanceName pizzakoordinator `
    -AgentUpn pizzakoordinator@jjazdev.org -DisplayName PizzaKoordinator -MailNickname pizzakoordinator `
    -IdentityDisplayName 'PizzaKoordinator Identity'
```

6. Přidejte uživatele **PizzaKoordinator** do týmu a kanálu, kde jsou Kuryr1–3 a admin.
7. Napište v kanálu `@PizzaKoordinator ahoj` – tím se agent na kanál naváže a od té doby
   do něj oznamuje nové objednávky.

Bridge identita potřebuje roli **Azure AI User** na Foundry projektu (skript ji přidělí),
aby mohla volat agenta a vytvářet verze skillu i agenta.

## Použití v kanálu

- Kurýr: `@PizzaKoordinator beru 3f2a1b9c v 18:30` → pozvánka kurýrovi + e-mail adminovi.
- Kurýr: `@PizzaKoordinator 3f2a1b9c doručeno` → objednávka `Completed`.
- Kurýr: `@PizzaKoordinator chci jezdit jen Po–St 17–21 v Praze 5` → návrh změny s diffem.
- Admin: `@PizzaKoordinator schvaluji a1b2c3` nebo `@PizzaKoordinator zamitam a1b2c3`.

## Lokální vývoj

```powershell
dotnet test .\pizza-koordinator\PizzaKoordinator.slnx
```

Konfigurace je v sekci `Koordinator` (`appsettings.json`), kurýři v `Koordinator:Couriers`.
`AllowLocalAuthBypass` vypne autorizaci tool endpointů jen v `Development`.

## Omezení

- Stav (sledované objednávky, přidělení, čekající žádosti o změnu) je v paměti → Container App
  běží s právě jednou replikou. Po restartu bridge znovu oznámí objednávky ve stavu `New`
  a čekající žádosti o změnu preferencí je nutné podat znovu; kanál se naváže první zprávou.
- Agentic user v kanálu reaguje jen na zprávy, kde je @zmíněn – kurýři musí psát `@PizzaKoordinator`.
- Kurýři jsou v oznámeních uvedeni jménem, ne skutečnou Teams @zmínkou.
- Vytvoření nové verze agenta po schválení používá preview REST API (`/agents/{name}/versions`);
  pokud selže, nová verze skillu je už výchozí a stačí znovu spustit `Deploy-FoundryAgent.ps1`
  (ten si vezme aktuální výchozí verzi `courier-preferences`).
