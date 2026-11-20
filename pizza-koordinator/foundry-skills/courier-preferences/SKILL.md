---
name: courier-preferences
description: Preference rozvozu kurýrů Kuryr1, Kuryr2 a Kuryr3 (časová okna a lokality v Praze) pro výběr kurýra k objednávce.
---

# Preference kurýrů

Tento skill je jediný zdroj pravdy o preferencích kurýrů. Měnit ho smí jen
PizzaKoordinator po schválení adminem (skill `preference-change-approval`).

| Kurýr  | E-mail             | Dny        | Časové okno | Preferované lokality     | Poznámka                  |
|--------|--------------------|------------|-------------|--------------------------|---------------------------|
| Kuryr1 | kuryr1@jjazdev.org | Po–Pá      | 10:00–14:00 | Praha 1, Praha 2, Praha 3 | Jezdí na kole, max 3 pizzy |
| Kuryr2 | kuryr2@jjazdev.org | Po–Pá      | 16:00–22:00 | Praha 4, Praha 5          | Skútr, i větší objednávky  |
| Kuryr3 | kuryr3@jjazdev.org | So–Ne      | 11:00–21:00 | Praha 6, Praha 7, Praha 8 | Auto, víkendy celý den     |
| Kuryr3 | kuryr3@jjazdev.org | Po–Pá      | 18:00–22:00 | Praha 6, Praha 7, Praha 8 | Ve všední dny jen večer    |

## Jak vybírat

1. Urči lokalitu z adresy zákazníka (např. „Praha 5“ nebo název čtvrti — Smíchov = Praha 5,
   Dejvice = Praha 6, Holešovice = Praha 7, Karlín = Praha 8, Vinohrady = Praha 2/3,
   Nusle = Praha 4, Staré Město = Praha 1).
2. Preferuj kurýra, jehož časové okno pokrývá navržený čas rozvozu a lokalita sedí.
3. Když sedí víc kurýrů, doporuč toho s užší specializací na lokalitu.
4. Když nesedí nikdo, doporuč nejbližší shodu a jasně řekni, co nesedí.
5. Preference jsou doporučení, ne zákaz: pokud se kurýr přihlásí sám, smí rozvoz převzít.
