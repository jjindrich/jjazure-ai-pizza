window.pizzaCatalog = {
    revealForm(panel) {
        const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        panel.scrollIntoView({ behavior: reducedMotion ? "instant" : "smooth", block: "start" });
        panel.querySelector("#pizza-name").focus({ preventScroll: true });
    }
};
