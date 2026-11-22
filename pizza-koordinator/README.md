# Pizza Koordinator

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
| Změna preference se schválením admina | tool `proposePreferenceChange` → diff do kanálu i e-mailem → admin napíše `@Pizza Koordinator schvaluji <ID>` / `zamitam <ID>` → bridge vytvoří novou verzi skillu a novou verzi agenta |

Schválení/zamítnutí vyhodnocuje bridge deterministicky (ne LLM) a přijme ho jen od
uživatele s `AdminAadObjectId`. Dokud admin nerozhodne, skill se nemění.

Orders API dostalo filtr `GET /api/orders/?status=New` (zbytek API se nemění).

## Nasazení

**Instance `pizzakoordinator@jjazdev.org` už je vidět v Microsoft 365 admin centru.**
Pro její použití znovu neimportujte ZIP ani nevytvářejte instanci. Přesná ID, zdroje
v `rg-jjazure-ai-pizza-apps` a postup pro nové nasazení jsou na začátku
[`DEPLOYMENT.md`](DEPLOYMENT.md#aktualni-nasazeni).

Pořadí pro nové nasazení podle MVP: příprava API a identity → registrace blueprintu
a sestavení ZIPu → nasazení bridge → nasazení Foundry agenta a skillů → ruční import
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
- Agentic user v kanálu reaguje jen na zprávy, kde je @zmíněn – kurýři musí psát `@Pizza Koordinator`.
- Kurýři jsou v oznámeních uvedeni jménem, ne skutečnou Teams @zmínkou.
- Vytvoření nové verze agenta po schválení používá preview REST API (`/agents/{name}/versions`);
  pokud selže, nová verze skillu je už výchozí a stačí znovu spustit `Deploy-FoundryAgent.ps1`
  (ten si vezme aktuální výchozí verzi `courier-preferences`).
