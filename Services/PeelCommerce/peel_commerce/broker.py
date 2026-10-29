"""Killable, bounded verification worker; no transaction persistence or retry queue."""
import json
import selectors
import subprocess
import sys
import threading
import time
from .config import SERVICE_ROOT
from .contract import MAX_LEASE, PRODUCTS, Unavailable, strict_json

WORKER_SECONDS = 12
MAX_WORKER_OUTPUT = 4096


def validate_response(obj, request, now):
    base = {"schema", "requestId", "nonce", "pairingId", "sessionId", "decision", "reason", "verifiedAt", "expiresAt"}
    if type(obj) is not dict:
        raise Unavailable("unavailable")
    grant = obj.get("decision") == "granted"
    if set(obj) != (base | {"productId", "ownership"} if grant else base):
        raise Unavailable("unavailable")
    if (type(obj["schema"]) is not int or obj["schema"] != 1 or
            any(obj[key] != request.wire()[key] for key in ("requestId", "nonce", "pairingId", "sessionId")) or
            type(obj["verifiedAt"]) is not int or type(obj["expiresAt"]) is not int or
            not now - WORKER_SECONDS - 2 <= obj["verifiedAt"] <= now + 1):
        raise Unavailable("unavailable")
    if grant:
        if (obj["reason"] != "active" or obj["productId"] not in PRODUCTS or
                obj["ownership"] not in ("purchased", "familyShared") or
                not now < obj["expiresAt"] <= obj["verifiedAt"] + MAX_LEASE):
            raise Unavailable("unavailable")
    elif (obj["decision"] != "denied" or obj["reason"] not in
          ("no_entitlement", "invalid_evidence", "revoked", "expired", "unsupported_environment") or
          obj["expiresAt"] != obj["verifiedAt"]):
        raise Unavailable("unavailable")
    return obj


class ProcessBroker:
    def __init__(self, config_path, timeout=WORKER_SECONDS, maximum_workers=2):
        self.config_path = config_path
        self.timeout = min(timeout, WORKER_SECONDS)
        self.capacity = threading.BoundedSemaphore(maximum_workers)

    def verify(self, request):
        if not self.capacity.acquire(blocking=False):
            raise Unavailable("busy")
        process = None
        try:
            # -I ignores PYTHONPATH, user site packages and the working directory.
            # stdin/stdout are memory pipes; JWS never appears in argv or files.
            process = subprocess.Popen([sys.executable, "-I", str(SERVICE_ROOT / "worker_entry.py"), self.config_path],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       close_fds=True)
            payload = json.dumps(request.wire(), separators=(",", ":")).encode("ascii")
            deadline = time.monotonic() + self.timeout
            output = bytearray()
            offset = 0
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdin, selectors.EVENT_WRITE)
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise Unavailable("unavailable")
                    for key, _ in selector.select(remaining):
                        if key.fileobj is process.stdin:
                            # Pipe writes <=4096 bytes are bounded and atomic.
                            import os
                            offset += os.write(process.stdin.fileno(), payload[offset:offset + 4096])
                            if offset == len(payload):
                                selector.unregister(process.stdin)
                                process.stdin.close()
                        else:
                            import os
                            chunk = os.read(process.stdout.fileno(), MAX_WORKER_OUTPUT + 1 - len(output))
                            if not chunk:
                                selector.unregister(process.stdout)
                            output.extend(chunk)
                            if len(output) > MAX_WORKER_OUTPUT:
                                raise Unavailable("unavailable")
                result = process.wait(timeout=max(0.01, deadline - time.monotonic()))
            if result != 0:
                raise Unavailable("unavailable")
            return validate_response(strict_json(bytes(output)), request, int(time.time()))
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise Unavailable("unavailable") from exc
        finally:
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait()
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                if process.stdout:
                    process.stdout.close()
            self.capacity.release()
