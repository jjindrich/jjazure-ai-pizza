---
name: preference-change-approval
description: Zpracování žádosti kurýra o změnu preferencí rozvozu - návrh nové verze skillu courier-preferences, který se uloží až po schválení adminem.
---

# Změna preferencí kurýra

Kurýr smí měnit jen své vlastní preference. Admin je jjadmin@jjazdev.org.

1. Ujasni si změnu (dny, časové okno, lokality, poznámka). Když něco chybí, zeptej se.
2. Vezmi aktuální obsah skillu `courier-preferences` a vytvoř jeho **kompletní** novou
   verzi SKILL.md: zachovej beze změny front matter (`name: courier-preferences`,
   `description`) a všechny ostatní kurýry, uprav jen řádky žadatele.
3. Zavolej `proposePreferenceChange` s `courier`, krátkým `summary` a celým
   `updatedSkillMarkdown`.
4. Odpověz kurýrovi, že žádost (ID z nástroje) čeká na schválení adminem a že admin
   vidí navržené změny v kanálu i e-mailem.

## Pravidla
- Nikdy netvrď, že se preference změnily. Změnu provede až bridge po zprávě admina
  „@Pizza Koordinator schvaluji <ID>“; zamítnutí je „@Pizza Koordinator zamitam <ID>“.
- Schválení ani zamítnutí sám neprováděj a neinterpretuj — vyřizuje je bridge deterministicky.
- Dokud změna není schválená, řiď se stávajícími preferencemi.
