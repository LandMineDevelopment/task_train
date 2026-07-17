"""Exercise the browser API against a running web service."""

import json
import os
from urllib.request import Request, urlopen


BASE_URL = os.environ.get("BROWSER_API_BASE_URL", "http://127.0.0.1:8000")


def get(path):
    return json.load(urlopen(f"{BASE_URL}{path}"))


def request(path, method, payload):
    body = json.dumps(payload).encode()
    response = Request(
        f"{BASE_URL}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    return json.load(urlopen(response))


def main():
    assert get("/api/health")["status"] == "ok"
    assert get("/api/conversations")["conversations"]

    created = request("/api/conversations", "POST", {"title": "Browser test"})
    conversation_id = created["conversation_id"]
    renamed = request(
        f"/api/conversations/{conversation_id}",
        "PATCH",
        {"title": "Renamed browser test"},
    )
    assert renamed["conversation"]["title"] == "Renamed browser test"

    queued = request(
        f"/api/conversations/{conversation_id}/messages",
        "POST",
        {"message": "Verify workflow dispatch."},
    )
    assert queued["status"] == "queued"
    detail = get(f"/api/conversations/{conversation_id}")
    assert detail["conversation"]["title"] == "Renamed browser test"
    assert any(
        task["id"] == queued["task_id"] and task["artifacts"] == []
        for task in detail["tasks"]
    )
    assert "Task Train" in urlopen(f"{BASE_URL}/").read().decode()
    print(queued["task_id"])


if __name__ == "__main__":
    main()
