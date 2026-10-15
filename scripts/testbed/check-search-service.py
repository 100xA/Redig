"""Exercise the production service with deterministic slow model/render substitutes; no model downloads."""
import atexit
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time


class Service:
    def __init__(self, binary, fail_once=False):
        self.folder = tempfile.TemporaryDirectory()
        self.messages = queue.Queue()
        self.events = []
        self.process = subprocess.Popen(
            [binary, self.folder.name], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env={**os.environ, "PROBE_FAIL_ONCE": str(int(fail_once))},
        )
        atexit.register(self.cleanup)
        threading.Thread(target=self.read, daemon=True).start()
        self.until(lambda message: message.get("event") == "ready")

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, **request):
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()

    def until(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while True:
            message = self.messages.get(timeout=max(0.001, deadline - time.monotonic()))
            self.events.append(message)
            if predicate(message):
                return message

    def cleanup(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=4)
        self.folder.cleanup()

    def stop(self):
        self.send(id=999, op="quit")
        self.process.wait(timeout=4)
        self.cleanup()


def check(binary):
    service = Service(binary)
    service.send(id=1, op="prewarm")
    started = time.monotonic()
    service.send(id=2, op="search", q="keyword", meaning=False)
    service.until(lambda message: message.get("id") == 2)
    warming_seconds = time.monotonic() - started
    assert warming_seconds < 0.3, warming_seconds
    service.until(lambda message: message.get("event") == "encoder" and message.get("state") == "ready")

    for generation in range(1, 51):
        service.send(id=100 + generation, op="embed_ahead", q=f"query-{generation}",
                     client="test", generation=generation)
    started = time.monotonic()
    service.send(id=300, op="search", q="query-50", meaning=False, client="test", generation=50)
    service.until(lambda message: message.get("id") == 300)
    assert time.monotonic() - started < 0.3
    service.send(id=301, op="search", q="query-50", meaning=True, client="test", generation=50)
    service.until(lambda message: message.get("id") == 301)
    embeddings = [message for message in service.events if message.get("event") == "probe_embed"]
    assert len(embeddings) <= 2, len(embeddings)

    for index in range(70):
        service.send(id=400 + index, op="render", path=f"/image-{index}", kind="image")
    started = time.monotonic()
    service.send(id=500, op="search", q="keyword", meaning=False)
    service.until(lambda message: message.get("id") == 500)
    rendering_seconds = time.monotonic() - started
    assert rendering_seconds < 0.3, rendering_seconds
    assert any(message.get("ok") is False and "queue is full" in message.get("error", "")
               for message in service.events)
    service.stop()

    retry = Service(binary, fail_once=True)
    retry.send(id=1, op="prewarm")
    retry.until(lambda message: message.get("state") == "unavailable")
    retry.send(id=2, op="prewarm")
    retry.until(lambda message: message.get("state") == "ready")
    retry.stop()
    print(json.dumps({
        "keyword_during_model_load_ms": round(warming_seconds * 1000, 2),
        "keyword_during_render_backlog_ms": round(rendering_seconds * 1000, 2),
        "embeddings_for_50_keystrokes": len(embeddings),
        "missing_model_recovery": "passed",
    }))


if __name__ == "__main__":
    check(sys.argv[1])
