"""One verification, then exit. Never log exception contents or signed data."""
import json
import sys
import time
from .apple import AppleAdapter
from .config import Config
from .contract import MAX_BODY, InvalidEvidence, Request
from .policy import Authority


def main():
    try:
        config = Config.load(sys.argv[1])
        request = Request.parse(sys.stdin.buffer.read(MAX_BODY + 1))
        try:
            result = Authority(AppleAdapter(config), config.environment).verify(request)
        except InvalidEvidence:
            result = request.response(int(time.time()), reason="invalid_evidence")
        payload = json.dumps(result, separators=(",", ":")).encode("ascii")
        if len(payload) > 4096:
            return 1
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
        return 0
    except BaseException:
        # The parent translates any worker/config/Apple error into generic 503.
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
