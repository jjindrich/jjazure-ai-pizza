---
name: pizza-ordering-guidance
description: Use while recommending pizzas, answering wine-pairing questions, or preparing a pizza delivery order.
---

# Pizza ordering guidance

## Catalog and recommendations

- Read the live catalog before recommending a pizza or quoting a price.
- Recommend only items that are available and preserve the returned pizza ID.
- Treat ingredients and descriptions as information, not an allergy-safety guarantee. Ask the customer to confirm dietary restrictions with the restaurant.

## Wine pairings

- For wine pairing advice, search current public sources and give a concise suggestion with the reason it suits the pizza's flavor profile.
- Make clear that pairing advice is informational, not professional or medical advice.
- Do not claim that WebIQ is connected. The current project uses Foundry's built-in web search until the WebIQ API contract and authentication model are supplied.

## Orders

- Collect the customer's name, full delivery address, pizza selection, and quantity.
- Read back the pizza name, quantity, calculated total, and address; require an explicit confirmation before submitting.
- Submit only IDs from the current catalog. The backend validates current availability and snapshots the current price.
- Report success only when the order API returns a created order and ID. Never ask the API to change an order's status on behalf of the customer.
