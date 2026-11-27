import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "foundry" / "pizzaops" / "azure.yaml"
SKILLS = ROOT / "foundry-skills"
TEAMS = ROOT / "teams" / "pizzaops-agent-factory"

EXPECTED_OPERATIONS = {
    "createPizzaOpsTask",
    "getPizzaOpsTask",
    "updatePizzaOpsTask",
    "calculatePizzaPlan",
    "getCalendarAvailability",
    "createCalendarEvent",
    "updateCalendarEvent",
    "checkPolicy",
    "requestApproval",
    "decideApproval",
    "scheduleWakeup",
    "createNotification",
}

EXPECTED_SKILLS = {
    "pizza-delivery-planning",
    "meeting-calendar-coordination",
    "autonomous-task-continuation",
    "human-approval-and-policy",
}


def test_foundry_manifest() -> None:
    text = AGENT.read_text(encoding="utf-8")
    assert "kind: prompt" in text
    assert "type: microsoft_copilot_preview" in text
    assert "kind: hosted" not in text
    assert "type: project_connection" in text
    assert "project_connection_id: ${PIZZAOPS_OPENAPI_CONNECTION_ID}" in text

    operations = set(re.findall(r"operationId:\s*([A-Za-z0-9_]+)", text))
    assert operations == EXPECTED_OPERATIONS, sorted(EXPECTED_OPERATIONS - operations)

    for skill in EXPECTED_SKILLS:
        assert f"name: {skill}" in text
        assert (SKILLS / skill / "SKILL.md").is_file()


def test_skill_frontmatter() -> None:
    for name in EXPECTED_SKILLS:
        text = (SKILLS / name / "SKILL.md").read_text(encoding="utf-8")
        assert text.startswith("---\n")
        assert re.search(rf"^name:\s*{re.escape(name)}$", text, flags=re.MULTILINE)
        assert re.search(r"^description:\s*\S", text, flags=re.MULTILINE)


def test_teams_templates() -> None:
    manifest_path = TEAMS / "manifest.preview.json"
    template_path = TEAMS / "agentic-user.template.json"

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    template = json.loads(template_path.read_text(encoding="utf-8"))
    assert manifest["manifestVersion"].startswith("1.")
    assert manifest.get("agenticUserTemplates")
    assert template["communicationProtocol"] == "activityProtocol"
    assert manifest["id"] == "00000000-0000-0000-0000-000000000000"
    assert template["agentIdentityBlueprintId"] == "00000000-0000-0000-0000-000000000000"


def main() -> None:
    test_foundry_manifest()
    test_skill_frontmatter()
    test_teams_templates()
    print("PizzaOps declarative configuration is internally consistent.")


if __name__ == "__main__":
    main()
