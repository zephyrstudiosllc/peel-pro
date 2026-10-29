"""Local cPanel cron maintenance; emits counts only, never account IDs/tokens/emails."""
import json
import sys
import time

from .apple import AppleTransport
from .app import process_revocation
from .config import Settings
from .store import Store


def run(settings=None, transport=None, now=None):
    settings = settings or Settings.from_environment()
    settings.validate()
    transport = transport or AppleTransport(settings)
    store = Store(settings)
    now = int(time.time()) if now is None else now
    with store.db() as db:
        store.prune(db, now)
        jobs = db.execute("SELECT id FROM revocations WHERE next_attempt<=? ORDER BY created LIMIT 5", (now,)).fetchall()
    completed = sum(process_revocation(store, transport, row["id"], now) for row in jobs)
    with store.db() as db:
        pending = db.execute("SELECT COUNT(*) FROM revocations").fetchone()[0]
        overdue = db.execute("SELECT COUNT(*) FROM revocations WHERE created<?", (now - 86400,)).fetchone()[0]
        critical = db.execute("SELECT COUNT(*) FROM revocations WHERE created<?", (now - 7*86400,)).fetchone()[0]
        uncertain = db.execute("SELECT COUNT(*) FROM grant_reservations WHERE expires<=?", (now,)).fetchone()[0]
    # No silent expiry of still-needed revocation credentials. 24h warning; 7d requires operator action.
    return {"completed": completed, "pending": pending, "overdue_24h": overdue, "requires_action_7d": critical, "uncertain_operations_5m": uncertain}


if __name__ == "__main__":
    try:
        result = run()
        print(json.dumps(result, sort_keys=True))
        sys.exit(2 if result["overdue_24h"] or result["uncertain_operations_5m"] else 0)
    except Exception:
        print('{"error":"maintenance_unavailable"}')
        sys.exit(1)
