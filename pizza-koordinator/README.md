# Pizza Koordinator

Autonomní agent v Microsoft Teams kanálu, který hlídá nové objednávky pizzy
z Orders API a koordinuje jejich rozvoz mezi kurýry **Kuryr1**, **Kuryr2** a **Kuryr3**.
Vychází z ukázky [`mvp-pizzaops`](../mvp-pizzaops), kterou nemění.

## Jak to funguje

```
                 veřejně (DMZ)                          │  privátně (ACA Sandboxes)
Teams kanál ──Agent 365──►┐                             │
                          ├─► Gateway ca-pizzakoordinator ──JWT + Private Link──► Worker v sbg-pizzakoordinator
Foundry agent ─OpenAPI /v1┘   jen ověří volajícího        │                     OrderWatcher, koordinace, skills,
     │                        a přepošle, bez credentials │                     Graph (kalendář/mail), odpovědi do Teams
     │                        agenta a bez Foundry/Graph  │                     Worker ──poll ?status=New──► Orders API
     └──Agent Identity──► Orders API /mcp (read-only)
     skills: courier-preferences | delivery-coordination | preference-change-approval
```

Gateway je jediná veřejná komponenta (DMZ): ověří token Teams/Agent 365 i Foundry, propustí jen
zprávy (`message`) a `/v1` nástroje a předá je Workeru se svou managed identity. Nemá credentials
blueprintu, přístup k Foundry, Graphu ani business logiku; když jsou credentials nastavené,
odmítne start. Worker běží v **Azure Container Apps Sandbox**, ne v běžné Container App
ani v Dynamic Session. Jeho port 8080 je dostupný přes Private Endpoint a přijme pouze
token Gateway identity. SandboxGroup je připojena k samostatnému **Express environmentu**
s vypnutým veřejným přístupem; veřejné prostředí Gateway se nemění.

| Komponenta | Ingress | Identita | Oprávnění |
|---|---|---|---|
| Gateway `ca-pizzakoordinator` | veřejný | `id-pizzakoordinator-gateway` | AcrPull, app role `PizzaKoordinator.Tool` (volání Workeru). Teams token ověřuje proti blueprint ClientId bez credentials, Foundry token podle `azp` projektu. |
| Worker v `sbg-pizzakoordinator` | Private Link, pouze port 8080 | `id-pizzakoordinator` připojená k SandboxGroup | AcrPull, Foundry User, federace s blueprintem (odpovědi do Teams, Graph). Volajícího ověřuje podle `azp` = Gateway MI. |
| Foundry agent | — | MI projektu / Agent Identity | MI projektu volá Gateway `/v1`, Agent Identity volá přímo Orders `/mcp`. |

Sandbox má vlastní disk image importovaný z C# image v ACR. Běží právě jeden Worker;
automatické uspávání a mazání jsou vypnuté, protože odchozí polling se nepočítá jako
aktivita zabraňující uspání. Egress je standardně zakázaný, s allowlistem Orders,
Foundry, Entra, Graph a potřebných Bot Framework/Teams adres.

Gateway nemá oprávnění vytvářet, zastavovat ani spravovat Sandbox nebo v něm spouštět
příkazy. To dělají nasazovací skripty pod identitou správce. SandboxGroup je vyhrazená
Workeru, protože její managed identity mohou používat i ostatní Sandboxy v téže skupině.

Agent přes vlastní Foundry Agent Identity čte objednávky přes Orders MCP (`list_new_orders`,
`get_order`) přímo, bez Gateway/Workeru. MCP se povolí pouze při shodě tenant ID, audience
a allowlistovaného client ID. Přidělení a dokončení zatím zůstávají nástroji Workeru (přes Gateway);
Worker také dál sleduje vznik objednávek. Stávající REST API se tímto krokem nemění.

| Požadavek | Kde je to řešené |
|---|---|
| Nová objednávka → zpráva do kanálu a výzva kurýrům | Worker `OrderWatcher` (polling) → agent (`delivery-coordination`) → proaktivní zpráva do kanálu |
| Urgence po 3 minutách ticha | `CoordinatorState.TakeDueForUrge` (každá zpráva kurýra časovač resetuje, max 5 urgencí) |
| Přidělení → pozvánka do kalendáře + e-mail adminovi | tool `assignDelivery`: Graph `/me/events` (místo = adresa zákazníka) a `/me/sendMail` na `jjadmin@jjazdev.org` |
| Samostatná schůzka v kalendáři | tool `scheduleMeeting`: po potvrzení údajů vytvoří událost s účastníky přes Graph `/me/events` pod účtem agenta |
| „Doručeno“ → objednávka hotová | tool `completeDelivery`: posune objednávku v Orders API až do `Completed` |
| Preference kurýrů | skill [`courier-preferences`](foundry-skills/courier-preferences/SKILL.md) (zkušební data) |
| Změna preference se schválením admina | tool `proposePreferenceChange` → diff do kanálu i e-mailem → admin napíše `@Pizza Koordinator schvaluji <ID>` / `zamitam <ID>` → Worker vytvoří novou verzi skillu a novou verzi agenta |

Schválení/zamítnutí vyhodnocuje Worker deterministicky (ne LLM) a přijme ho jen od
uživatele s `AdminAadObjectId`. Dokud admin nerozhodne, skill se nemění.
Agent je instruován požádat před vytvořením schůzky o potvrzení; toto potvrzení
zatím vynucuje konverzační instrukce, nikoli samostatný autorizační mechanismus.
Po potvrzení vede cesta přes Foundry `scheduleMeeting`, Gateway a Worker k Graph
`POST /me/events`. Worker použije Agent 365 User `pizzakoordinator@jjazdev.org`,
nikoli identitu tazatele ani Foundry agenta. Graph po vytvoření události s účastníky
odešle pozvánky; úspěšné vytvoření samo o sobě nepotvrzuje doručení do schránek.
Při nejasném výsledku je třeba před opakováním zkontrolovat kalendář agenta.

Orders API má filtr `GET /api/orders/?status=New` a volitelný, zabezpečený read-only endpoint
`/mcp`. MCP se aktivuje nastavením `Pizza__AgentMcp__TenantId`,
`Pizza__AgentMcp__Audience` a `Pizza__AgentMcp__AllowedClientId`; bez úplné konfigurace zůstává
vypnuté. Ověřte skutečné `azp`/`appid` claims tokenu Foundry Agent Identity před povolením.

## Nasazení

**Instance `pizzakoordinator@jjazdev.org` už je vidět v Microsoft 365 admin centru.**
Pro její použití znovu neimportujte ZIP ani nevytvářejte instanci. Přesná ID, zdroje
v `rg-jjazure-ai-pizza-apps` a postup pro nové nasazení jsou na začátku
[`DEPLOYMENT.md`](DEPLOYMENT.md#aktualni-prostredi).

Pořadí pro nové nasazení podle MVP: příprava API a identit → registrace blueprintu
a sestavení ZIPu → nasazení Workeru a Gateway → nasazení Foundry agenta a skillů → ruční import
ZIPu do Microsoft 365 a kontrola blueprintu šablony → vytvoření identity a účtu
pomocí `Provision-Agent365Instance.ps1`. Přímá publikace z Foundry tento import nenahrazuje.

Pro osobní test otevřete v Teams chat s `pizzakoordinator@jjazdev.org`. Pro rozvoz
přidejte **Pizza Koordinator** do týmu s kurýry a adminem a napište v cílovém kanálu
`@Pizza Koordinator ahoj`. Tím se oznámení navážou na kanál místo osobního chatu.

## Použití v kanálu

- Kurýr: `@Pizza Koordinator beru 3f2a1b9c v 18:30` → pozvánka kurýrovi + e-mail adminovi.
- Kurýr: `@Pizza Koordinator 3f2a1b9c doručeno` → objednávka `Completed`.
- Kurýr: `@Pizza Koordinator chci jezdit jen Po–St 17–21 v Praze 5` → návrh změny s diffem.
- Admin: `@Pizza Koordinator schvaluji a1b2c3` nebo `@Pizza Koordinator zamitam a1b2c3`.
- Schůzka: `@Pizza Koordinator naplánuj schůzku Pizza 1. 12. 2026 v 8:00 na 30 minut v Praze, účastník admin@example.cz` → potvrzení údajů → pozvánka z účtu agenta.

## Lokální vývoj

```powershell
dotnet test .\pizza-koordinator\PizzaKoordinator.slnx
.\pizza-koordinator\tests\Test-WorkerSandbox.ps1
```

Worker má konfiguraci v sekci `Koordinator` (`appsettings.json`, kurýři v `Koordinator:Couriers`),
Gateway v sekci `Gateway` (`WorkerUrl` = adresa Workeru). `AllowLocalAuthBypass` vypne ověřování
volajících a tokeny mezi Gateway a Workerem jen v `Development`.
Offline test nasazovacího kontraktu potřebuje CLI `aca`, ale ne přihlášení do Azure.
Gateway `/health` kontroluje samotný proces; `/health/ready` provede read-only volání
Workera se skutečnou identitou Gateway a ověří tak i síťovou cestu.

## Omezení

- Stav (sledované objednávky, přidělení, čekající žádosti o změnu) je v paměti Workeru → Worker
  běží v právě jednom aktivním Sandboxu (Gateway je bezstavová). Po restartu Worker znovu oznámí objednávky
  ve stavu `New` a čekající žádosti o změnu preferencí je nutné podat znovu; kanál se naváže první zprávou.
- Nový image nebo konfigurace vyžaduje `-ReplaceWorker`. Skript nejprve zastaví starý
  Sandbox a ponechá ho pro ruční obnovu; stav se do nového Workera nepřenáší. Ruční
  Memory snapshot není náhradou databáze ani automatické obnovy procesu po pádu.
- Private Endpoint, Express environment a stále běžící Sandbox přidávají provozní náklady.
- Agentic user v kanálu reaguje jen na zprávy, kde je @zmíněn – kurýři musí psát `@Pizza Koordinator`.
- Kurýři jsou v oznámeních uvedeni jménem, ne skutečnou Teams @zmínkou.
- Vytvoření nové verze agenta po schválení používá preview REST API (`/agents/{name}/versions`);
  pokud selže, nová verze skillu je už výchozí a stačí znovu spustit `Deploy-FoundryAgent.ps1`
  (ten si vezme aktuální výchozí verzi `courier-preferences`).
