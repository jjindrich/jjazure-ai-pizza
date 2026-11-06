"""Local-only catalog UI and documented API smoke tests. Requires Python Playwright."""

import argparse
import base64
from pathlib import Path
from urllib.parse import urlparse
from uuid import uuid4

from playwright.sync_api import expect, sync_playwright


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
)


def assert_form_revealed(page):
    expect(page.locator("#pizza-name")).to_be_focused()
    page.wait_for_function(
        """() => {
            const rect = document.querySelector('#pizza-name').getBoundingClientRect();
            return rect.top >= 0 && rect.bottom <= window.innerHeight;
        }"""
    )


def check_ui(browser, catalog, width, reduced_motion, artifacts, currency_code):
    context = browser.new_context(
        viewport={"width": width, "height": 900},
        reduced_motion=reduced_motion,
    )
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    name = f"UI pizza {width} {uuid4().hex[:8]}"
    pizza_id = None
    try:
        page.goto(catalog, wait_until="networkidle")
        count = page.locator(".pizza-card").count()
        notice = page.get_by_text("Currency is not configured.", exact=False)
        if currency_code:
            expect(notice).to_have_count(0)
        else:
            expect(notice).to_be_visible()
        assert all("\u00a4" not in text for text in page.locator(".price").all_text_contents())

        page.locator(".page-heading").get_by_role("button", name="Add pizza", exact=True).click()
        assert_form_revealed(page)
        form = page.locator("#pizza-form")
        form.get_by_role("button", name="Add pizza", exact=True).click()
        expect(form.locator(".validation-errors")).to_contain_text("Name is required")
        form.get_by_label("Name", exact=True).fill(name)
        form.get_by_label("Ingredients and description").fill("Tomato, mozzarella, basil")
        form.get_by_label("Price", exact=False).fill("12.50")
        form.get_by_label("Available to order").uncheck()
        form.get_by_role("button", name="Add pizza", exact=True).click()
        expect(page.get_by_role("status")).to_have_text("Pizza added.")
        expect(page.locator(".pizza-card")).to_have_count(count + 1)
        pizza = next(item for item in context.request.get(f"{catalog}/api/catalog/pizzas").json() if item["name"] == name)
        pizza_id = pizza["id"]
        assert pizza["price"] == 12.5 and not pizza["isAvailable"]

        card = page.locator(".pizza-card").filter(has=page.get_by_role("heading", name=name, exact=True))
        expect(card.locator(".price")).to_have_text(f"12.50 {currency_code}" if currency_code else "12.50")
        card.get_by_role("button", name="Edit", exact=True).click()
        assert_form_revealed(page)
        expect(form.get_by_label("Name", exact=True)).to_have_value(name)
        expect(form.get_by_label("Price", exact=False)).to_have_value("12.50")
        form.get_by_label("Name", exact=True).fill(name + " edited")
        form.get_by_label("Price", exact=False).fill("13.75")
        form.get_by_label("Available to order").check()
        form.get_by_role("button", name="Save changes").click()
        expect(page.get_by_role("status")).to_have_text("Pizza updated.")
        updated = context.request.get(f"{catalog}/api/catalog/pizzas/{pizza_id}").json()
        assert updated["name"] == name + " edited" and updated["price"] == 13.75 and updated["isAvailable"]

        card = page.locator(".pizza-card").filter(has=page.get_by_role("heading", name=name + " edited", exact=True))
        card.locator('input[type="file"]').set_input_files(
            {"name": "pizza.png", "mimeType": "image/png", "buffer": PNG}
        )
        expect(page.get_by_role("status")).to_have_text("Pizza photo updated.")
        card.get_by_role("button", name="Edit", exact=True).click()
        assert_form_revealed(page)
        if artifacts:
            page.screenshot(path=str(artifacts / f"catalog-{width}.png"), full_page=False)

        form.get_by_label("Name", exact=True).fill("Unsaved draft")
        form.get_by_role("button", name="Cancel", exact=True).click()
        expect(form.get_by_label("Name", exact=True)).to_have_value("")
        assert context.request.get(f"{catalog}/api/catalog/pizzas/{pizza_id}").json()["name"] == name + " edited"

        card.get_by_role("button", name="Edit", exact=True).click()
        assert_form_revealed(page)
        page.locator(".page-heading").get_by_role("button", name="Add pizza", exact=True).click()
        assert_form_revealed(page)
        expect(form.get_by_label("Name", exact=True)).to_have_value("")
        expect(form.get_by_role("heading")).to_have_text("Add a pizza")
        expect(form.locator(".validation-errors")).to_have_count(0)

        card.get_by_role("button", name="Edit", exact=True).click()
        card.get_by_role("button", name="Delete", exact=True).click()
        expect(page.get_by_role("status")).to_have_text("Pizza deleted.")
        expect(form.get_by_role("heading")).to_have_text("Add a pizza")
        expect(page.locator(".pizza-card")).to_have_count(count)
        pizza_id = None

        page.goto(f"{catalog}/api-docs", wait_until="networkidle")
        expect(page.get_by_role("heading", name="API documentation", exact=True)).to_be_visible()
        expect(page.locator("main")).to_contain_text("POST /api/catalog/pizzas")
        expect(page.locator("main")).to_contain_text("PUT /api/orders/{id}/status")
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        assert not errors, errors
        print(f"PASS UI {width}px, motion={reduced_motion}: create/validate/edit/focus/scroll/photo/cancel/delete/docs")
    finally:
        if pizza_id:
            context.request.delete(f"{catalog}/api/catalog/pizzas/{pizza_id}")
        context.close()


def check_service_links(browser, catalog, orders, width):
    context = browser.new_context(viewport={"width": width, "height": 900})
    try:
        page = context.new_page()
        page.goto(catalog, wait_until="networkidle")
        for label, destination in [("Orders", f"{orders}/orders"), ("Menu", f"{catalog}/")]:
            toggler = page.get_by_title("Navigation menu")
            if toggler.is_visible():
                toggler.check()
            link = page.get_by_role("navigation").get_by_role("link", name=label)
            expect(link).to_have_attribute("href", destination)
            link.click()
            page.wait_for_url(destination)
            expect(page.locator("main")).to_be_visible()
        print(f"PASS navigation {width}px: Catalog -> Orders -> Catalog")
    finally:
        context.close()


def check_apis(browser, catalog, orders, currency_code):
    context = browser.new_context()
    request = context.request
    pizza_id = None
    try:
        for origin in [catalog, orders]:
            response = request.get(f"{origin}/health/ready")
            assert response.status == 200 and response.text() == "Healthy"
            page = context.new_page()
            page.goto(f"{origin}/api-docs")
            expect(page.get_by_role("heading", name="API documentation", exact=True)).to_be_visible()
            page.close()

        invalid = request.post(f"{catalog}/api/catalog/pizzas", data={"name": "N", "description": "D", "price": 0})
        assert invalid.status == 400 and "request" in invalid.json()["errors"]
        body = {"name": "API example", "description": "Tomato and basil", "price": 10.5, "isAvailable": True}
        response = request.post(f"{catalog}/api/catalog/pizzas", data=body)
        assert response.status == 201
        pizza = response.json()
        pizza_id = pizza["id"]
        assert response.headers["location"] == f"/api/catalog/pizzas/{pizza_id}"
        assert set(pizza) == {"id", "name", "description", "price", "imageUrl", "isAvailable"}
        assert request.get(f"{catalog}/api/catalog/pizzas/{pizza_id}").json() == pizza
        assert any(item["id"] == pizza_id for item in request.get(f"{catalog}/api/catalog/pizzas").json())

        updated = request.put(f"{catalog}/api/catalog/pizzas/{pizza_id}", data=body | {"name": "Updated API example"})
        assert updated.status == 200 and updated.json()["name"] == "Updated API example"
        invalid_image = request.post(
            f"{catalog}/api/catalog/pizzas/{pizza_id}/image",
            multipart={"file": {"name": "bad.png", "mimeType": "image/png", "buffer": b"not an image"}},
        )
        assert invalid_image.status == 400 and "error" in invalid_image.json()
        image = request.post(
            f"{catalog}/api/catalog/pizzas/{pizza_id}/image",
            multipart={"file": {"name": "pizza.png", "mimeType": "image/png", "buffer": PNG}},
        )
        assert image.status == 200
        photo = request.get(catalog + image.json()["imageUrl"])
        assert photo.status == 200 and photo.body() == PNG

        response = request.post(
            f"{orders}/api/orders/",
            data={"customerName": "Example Customer", "customerAddress": "1 Example Street",
                  "items": [{"pizzaId": pizza_id, "quantity": 2}]},
        )
        assert response.status == 201, response.text()
        order = response.json()
        order_id = order["id"]
        assert response.headers["location"] == f"/api/orders/{order_id}"
        assert order["status"] == "New" and order["total"] == 21
        assert order["items"][0]["lineTotal"] == 21
        assert request.get(f"{orders}/api/orders/{order_id}").json() == order
        assert any(item["id"] == order_id for item in request.get(f"{orders}/api/orders/").json())
        skipped = request.put(f"{orders}/api/orders/{order_id}/status", data={"status": "Completed"})
        assert skipped.status == 400 and "status" in skipped.json()["errors"]
        for status in ["Preparing", "OutForDelivery", "Completed"]:
            response = request.put(f"{orders}/api/orders/{order_id}/status", data={"status": status})
            assert response.status == 200 and response.json()["status"] == status

        page = context.new_page()
        page.goto(f"{orders}/orders", wait_until="networkidle")
        row = page.locator("tbody tr").filter(has=page.get_by_text(order_id.replace("-", "")[:8], exact=True))
        expect(row.locator("td").nth(3)).to_have_text(f"21.00 {currency_code}" if currency_code else "21.00")
        expect(page.get_by_role("combobox")).to_contain_text(
            f"10.50 {currency_code}" if currency_code else "10.50"
        )
        page.close()

        assert request.delete(f"{catalog}/api/catalog/pizzas/{pizza_id}").status == 204
        assert request.get(f"{catalog}/api/catalog/pizzas/{pizza_id}").status == 404
        pizza_id = None
        print("PASS API: every documented endpoint, JSON shapes, upload/read image, validation and order lifecycle")
    finally:
        if pizza_id:
            request.delete(f"{catalog}/api/catalog/pizzas/{pizza_id}")
        context.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", default="http://127.0.0.1:5188")
    parser.add_argument("--orders", default="http://127.0.0.1:5189")
    parser.add_argument("--channel", help="Use an installed browser, e.g. msedge")
    parser.add_argument("--currency-code", help="Expected Pizza:CurrencyCode; omit for unconfigured services")
    parser.add_argument("--check-service-links", action="store_true", help="Check configured Catalog/Orders cross-service navigation")
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    for origin in [args.catalog, args.orders]:
        if urlparse(origin).hostname not in {"localhost", "127.0.0.1", "::1"}:
            parser.error("These tests create/delete synthetic pizzas and must only target local in-memory services.")
    if args.artifacts:
        args.artifacts.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=args.channel)
        try:
            check_ui(browser, args.catalog, 1440, "no-preference", args.artifacts, args.currency_code)
            check_ui(browser, args.catalog, 390, "reduce", args.artifacts, args.currency_code)
            check_apis(browser, args.catalog, args.orders, args.currency_code)
            if args.check_service_links:
                for width in [1440, 390]:
                    check_service_links(browser, args.catalog, args.orders, width)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
