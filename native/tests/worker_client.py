"""Bounded subprocess client for synthetic tests; never opens the screen/clipboard."""

import json
import os
import queue
import signal
import subprocess
import threading


class Worker:
    def __init__(self, command, policy="(version 1)(allow default)(deny network*)"):
        self.process = subprocess.Popen(
            ["/usr/bin/sandbox-exec", "-p", policy, *map(str, command)],
            cwd="/",
            env={**os.environ, "VECLIB_MAXIMUM_THREADS": "4", "TEXTPICKER_THREADS": "4"},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.messages = queue.Queue()

        def read():
            for line in self.process.stdout:
                try:
                    self.messages.put(json.loads(line))
                except ValueError:
                    self.messages.put({"type": "invalid-json"})
            self.messages.put({"type": "eof"})

        def drain():
            for _ in self.process.stderr:
                pass

        self.threads = [
            threading.Thread(target=read, daemon=True),
            threading.Thread(target=drain, daemon=True),
        ]
        for thread in self.threads:
            thread.start()

    def receive(self, seconds=12):
        return self.messages.get(timeout=seconds)

    def send(self, value):
        self.process.stdin.write(value + "\n")
        self.process.stdin.flush()
        return self.receive()

    def request(self, identifier, path):
        result = self.send(json.dumps({"id": identifier, "path": str(path)}))
        assert result.get("id") == identifier, result
        return result

    def finish(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        assert self.process.returncode == 0, self.process.returncode

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        if not self.process.stdin.closed:
            self.process.stdin.close()
        for thread in self.threads:
            thread.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()
