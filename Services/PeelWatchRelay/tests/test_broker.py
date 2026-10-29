from commerce_fixture import PositiveCommerceFixture
import base64
import dataclasses
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from uuid import uuid4

from peel_watch_relay import Account, DeviceGrant, RelayError, RelayStore
from peel_watch_relay.broker import encode


SECRET = "whsec_" + base64.b64encode(b"synthetic-test-key-do-not-use!!!").decode()
SECRET2 = "whsec_" + base64.b64encode(b"different-test-key-do-not-use!!").decode()


class Callback:
    def __init__(self):
        self.deliveries = []
        self.status = 202
        self.on_verify = None
        self.verifications = 0

    def post(self, url, body, headers):
        message = json.loads(body)
        if message.get("type") == "verification":
            self.verifications += 1
            if self.on_verify:
                self.on_verify()
            return 200, json.dumps({"challenge": message["challenge"]}).encode()
        self.deliveries.append((url, body, headers))
        if isinstance(self.status, Exception):
            raise self.status
        return self.status, b""


class Fixture:
    def setup_fixture(self, provider="dot"):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "private"
        self.clock = [1792485000.0]
        self.authorized = True
        self.grant = DeviceGrant("synthetic-watch", str(uuid4()))
        self.owner = Account("synthetic-account", provider, "chatGPT" if provider == "dot" else "x", str(uuid4()),
                             frozenset({"watch.connect", "watch.send", "watch.read", "host.deliver"}), self.clock[0] + 86400)
        self.store = RelayStore(self.directory, lambda a, d: self.authorized and d == self.grant, now=lambda: self.clock[0])
        self.store.commerce = PositiveCommerceFixture(lambda:self.clock[0])
        self.callback = Callback()
        self.link = self.store.connect(self.owner, self.grant, "selected-actual-agent-at-onboarding")
        self.route_id = self.link["route"]["routeID"]
        self.generation = self.link["route"]["generation"]
        self.agent = dataclasses.replace(self.owner,
            scopes=frozenset({"agent.inbox", "agent.reply", "agent.confirm", "agent.subscribe"}),
            route_ids=frozenset({self.route_id}))

    def ready(self):
        if self.owner.provider == "dot":
            self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
        self.store.confirm(self.agent, self.route_id, self.link["confirmationChallenge"])

    def send(self, text="A new synthetic Watch request", request_id=None):
        return self.store.send(self.owner, self.route_id, self.generation, request_id or str(uuid4()), text)

    def close_fixture(self):
        self.store.close()
        self.temp.cleanup()


class BrokerTests(Fixture, unittest.TestCase):
    def setUp(self):
        self.setup_fixture()

    def tearDown(self):
        self.close_fixture()

    def test_identity_alone_and_subscription_alone_cannot_enable_send(self):
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])
        with self.assertRaisesRegex(RelayError, "connection_not_confirmed"):
            self.send()
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])
        self.store.confirm(self.agent, self.route_id, self.link["confirmationChallenge"])
        self.assertTrue(self.store.status(self.owner, self.route_id)["ready"])
        self.assertTrue(self.store.status(self.owner, self.route_id)["automaticDeliveryReady"])
        with self.assertRaisesRegex(RelayError, "invalid_confirmation"):
            self.store.confirm(self.agent, self.route_id, self.link["confirmationChallenge"])

    def test_new_request_reply_and_idempotency_survive_restart(self):
        self.ready()
        receipt = self.send()
        repeated = self.send(request_id=receipt["requestID"])
        self.assertEqual(receipt, repeated)
        with self.assertRaisesRegex(RelayError, "reused_request_id"):
            self.send("different contents", receipt["requestID"])
        self.store.close()
        self.store = RelayStore(self.directory, lambda a, d: d == self.grant, now=lambda: self.clock[0])
        self.store.commerce = PositiveCommerceFixture(lambda:self.clock[0])
        inbox = self.store.inbox(self.agent, self.route_id)["requests"]
        self.assertEqual([receipt["requestID"]], [x["requestID"] for x in inbox])
        self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "stable-reply", "Actual reply path data")
        self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "stable-reply", "Actual reply path data")
        page = self.store.replies(self.owner, self.route_id, self.generation)
        self.assertEqual(1, len(page["replies"]))
        self.assertEqual(receipt["requestID"], page["replies"][0]["requestID"])
        self.assertEqual([], self.store.inbox(self.agent, self.route_id)["requests"])
        with self.assertRaisesRegex(RelayError, "reply_conflict"):
            self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "new-reply", "changed")

    def test_reply_cursor_preserves_late_out_of_order_reply(self):
        self.ready()
        first, second = self.send("one"), self.send("two")
        self.store.reply(self.agent, self.route_id, self.generation, second["requestID"], "r2", "second finished first")
        page = self.store.replies(self.owner, self.route_id, self.generation)
        self.store.reply(self.agent, self.route_id, self.generation, first["requestID"], "r1", "first finished later")
        late = self.store.replies(self.owner, self.route_id, self.generation, page["cursor"])
        self.assertEqual(first["requestID"], late["replies"][0]["requestID"])
        self.assertGreater(late["cursor"], page["cursor"])

    def test_escaped_max_replies_page_by_encoded_bytes_without_cursor_loss(self):
        self.ready()
        identifiers = []
        for n in range(15):
            receipt = self.send("request " + str(n))
            identifiers.append(receipt["requestID"])
            self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "reply_" + str(n), "\t\\\"" * 10666)
        after = 0
        received = []
        pages = 0
        while True:
            page = self.store.replies(self.owner, self.route_id, self.generation, after)
            self.assertLessEqual(len(encode(page)), 262144)
            if not page["replies"]:
                break
            self.assertGreater(page["cursor"], after)
            after = page["cursor"]
            received += [x["requestID"] for x in page["replies"]]
            pages += 1
        self.assertEqual(identifiers, received)
        self.assertGreater(pages, 1)

    def test_account_route_device_and_provider_fences(self):
        self.ready()
        for account in [dataclasses.replace(self.agent, principal="other-account"),
                        dataclasses.replace(self.agent, generation=str(uuid4())),
                        dataclasses.replace(self.agent, route_ids=frozenset())]:
            with self.assertRaises(RelayError):
                self.store.inbox(account, self.route_id)
        with self.assertRaisesRegex(RelayError, "device_access_denied"):
            self.store.assert_device(self.owner, DeviceGrant("another-watch", str(uuid4())), self.route_id)
        self.authorized = False
        with self.assertRaisesRegex(RelayError, "device_authority_changed"):
            self.store.inbox(self.agent, self.route_id)
        with self.assertRaisesRegex(RelayError, "identity_provider_mismatch"):
            dataclasses.replace(self.owner, identity_method="x")

    def test_reconnect_fences_old_agent_and_generation(self):
        self.ready()
        request = self.send()
        new_link = self.store.connect(self.owner, self.grant, "same-user-selected-agent")
        self.assertNotEqual(self.generation, new_link["route"]["generation"])
        with self.assertRaisesRegex(RelayError, "route_revoked"):
            self.store.reply(self.agent, self.route_id, self.generation, request["requestID"], "late", "obsolete")
        with self.assertRaisesRegex(RelayError, "route_revoked"):
            self.store.deliver_one(self.owner, self.route_id, self.callback)

    def test_late_callback_verification_cannot_resurrect_revoked_route(self):
        self.callback.on_verify = lambda: self.store.revoke(self.owner, self.route_id)
        with self.assertRaisesRegex(RelayError, "route_revoked"):
            self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
        self.assertEqual(0, self.store.db.execute("SELECT count(*) FROM subscriptions WHERE active=1").fetchone()[0])

    def test_delivery_ack_is_not_agent_reply_and_retry_keeps_event_id(self):
        self.ready()
        request = self.send()
        self.callback.status = TimeoutError()
        first = self.store.deliver_one(self.owner, self.route_id, self.callback)
        self.assertEqual("pending", first["state"])
        self.assertEqual("idle", self.store.deliver_one(self.owner, self.route_id, self.callback)["state"])
        self.clock[0] += 3
        self.callback.status = 202
        second = self.store.deliver_one(self.owner, self.route_id, self.callback)
        self.assertEqual(first["eventID"], second["eventID"])
        self.assertEqual("accepted", second["state"])
        self.assertFalse(second["agentReplyReceived"])
        self.assertEqual([], self.store.replies(self.owner, self.route_id, self.generation)["replies"])
        self.assertEqual(1, len(self.store.inbox(self.agent, self.route_id)["requests"]))
        self.assertEqual(request["requestID"], json.loads(self.callback.deliveries[0][1])["data"]["request_id"])
        self.assertNotEqual(self.callback.deliveries[0][2]["webhook-timestamp"], self.callback.deliveries[1][2]["webhook-timestamp"])

    def test_refresh_rotation_preserves_outbox_and_old_signature_briefly(self):
        self.ready()
        self.send()
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET2, self.callback)
        self.store.deliver_one(self.owner, self.route_id, self.callback)
        self.assertEqual(2, len(self.callback.deliveries[-1][2]["webhook-signature"].split(" ")))
        self.clock[0] += 61
        self.send("another")
        self.store.deliver_one(self.owner, self.route_id, self.callback)
        self.assertEqual(1, len(self.callback.deliveries[-1][2]["webhook-signature"].split(" ")))

    def test_expiry_and_unsubscribe_stop_future_deliveries(self):
        self.ready()
        self.send()
        self.store.unsubscribe(self.agent, self.route_id, "https://callback.example.com/events")
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])
        with self.assertRaisesRegex(RelayError, "connection_not_confirmed"):
            self.store.deliver_one(self.owner, self.route_id, self.callback)
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback, ttl_ms=60000)
        self.clock[0] += 61
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])

    def test_permanent_rejection_and_bounded_transient_retries(self):
        self.ready()
        self.send()
        self.callback.status = 410
        self.assertEqual("rejected", self.store.deliver_one(self.owner, self.route_id, self.callback)["state"])
        self.send("transient")
        self.callback.status = 503
        for n in range(6):
            result = self.store.deliver_one(self.owner, self.route_id, self.callback)
            self.clock[0] += 300
        self.assertEqual(6, result["attempts"])
        self.assertEqual("exhausted", result["state"])
        self.assertEqual("idle", self.store.deliver_one(self.owner, self.route_id, self.callback)["state"])

    def test_concurrent_duplicate_sends_create_one_durable_request(self):
        self.ready()
        identifier = str(uuid4())
        results = []
        def send():
            results.append(self.send(request_id=identifier))
        threads = [threading.Thread(target=send) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(2)
            self.assertFalse(thread.is_alive())
        self.assertEqual(8, len(results))
        self.assertEqual(1, len({x["receiptID"] for x in results}))
        self.assertEqual(1, self.store.db.execute("SELECT count(*) FROM deliveries").fetchone()[0])

    def test_capacity_preserves_uncertain_sends_and_private_store_required(self):
        self.ready()
        self.store.MAX_REQUESTS = 2
        self.send("one")
        self.send("two")
        with self.assertRaisesRegex(RelayError, "inbox_capacity"):
            self.send("third")
        self.assertEqual(2, len(self.store.inbox(self.agent, self.route_id)["requests"]))
        public = Path(self.temp.name) / "unsafe"
        public.mkdir(mode=0o755)
        with self.assertRaisesRegex(RelayError, "unsafe_storage"):
            RelayStore(public, lambda a, d: True)

    def test_account_signout_revokes_all_routes(self):
        self.ready()
        self.store.revoke_account(self.owner)
        with self.assertRaisesRegex(RelayError, "route_revoked"):
            self.store.inbox(self.agent, self.route_id)

    def test_expired_principal_and_expired_connection_challenge_fail_closed(self):
        expired = dataclasses.replace(self.owner, expires_at=self.clock[0])
        with self.assertRaisesRegex(RelayError, "principal_expired"):
            self.store.connect(expired, self.grant, "selected-agent")
        self.clock[0] += 601
        with self.assertRaisesRegex(RelayError, "invalid_confirmation"):
            self.store.confirm(self.agent, self.route_id, self.link["confirmationChallenge"])

    def test_expired_agent_cannot_read_or_reply_to_a_live_route(self):
        self.ready()
        request = self.send()
        expired = dataclasses.replace(self.agent, expires_at=self.clock[0])
        with self.assertRaisesRegex(RelayError, "principal_expired"):
            self.store.inbox(expired, self.route_id)
        with self.assertRaisesRegex(RelayError, "principal_expired"):
            self.store.reply(expired, self.route_id, self.generation, request["requestID"], "late", "expired reply")

    def test_callback_success_cache_is_bounded_and_rotation_reverifies(self):
        self.ready()
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
        self.assertEqual(1, self.callback.verifications)
        self.clock[0] += 301
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
        self.assertEqual(2, self.callback.verifications)
        self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET2, self.callback)
        self.assertEqual(3, self.callback.verifications)

    def test_only_one_store_can_own_the_database(self):
        with self.assertRaisesRegex(RelayError, "store_already_owned"):
            RelayStore(self.directory, lambda a, d: True)
        self.store.close()
        self.store = RelayStore(self.directory, lambda a, d: d == self.grant, now=lambda: self.clock[0])
        self.store.commerce = PositiveCommerceFixture(lambda:self.clock[0])
        self.assertEqual("authorizePlugin", self.store.status(self.owner, self.route_id)["state"])

    def test_forked_process_cannot_use_inherited_store_or_unlock_parent(self):
        child = os.fork()
        if child == 0:
            try:
                self.store.status(self.owner, self.route_id)
            except RelayError as error:
                if error.code != "store_process_changed":
                    os._exit(2)
            else:
                os._exit(3)
            try:
                self.store.close()
            except RelayError as error:
                os._exit(0 if error.code == "store_process_changed" else 4)
            os._exit(5)
        _, result = os.waitpid(child, 0)
        self.assertTrue(os.WIFEXITED(result))
        self.assertEqual(0, os.WEXITSTATUS(result))
        with self.assertRaisesRegex(RelayError, "store_already_owned"):
            RelayStore(self.directory, lambda a, d: True)
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])

    def test_invalid_unicode_is_a_bounded_domain_error(self):
        self.ready()
        with self.assertRaisesRegex(RelayError, "invalid_unicode"):
            self.send("lone surrogate \ud800")
        with self.assertRaisesRegex(RelayError, "invalid_unicode"):
            self.store.connect(self.owner, self.grant, "\ud800")
        receipt = self.send()
        with self.assertRaisesRegex(RelayError, "invalid_reply"):
            self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "bad-reply", "no\x00control")

    def test_expired_waiting_connect_does_not_mutate_the_route(self):
        errors = []
        account = dataclasses.replace(self.owner, expires_at=self.clock[0] + 1)
        entered = threading.Event()
        def authority(account, grant):
            if threading.current_thread() is not threading.main_thread():
                entered.set()  # Initial authority check, after expiry admission.
            return grant == self.grant
        self.store.authority = authority
        def connect():
            try:
                self.store.connect(account, self.grant, "late-selection")
            except RelayError as error:
                errors.append(error.code)
        with self.store.lock:
            thread = threading.Thread(target=connect)
            thread.start()
            self.assertTrue(entered.wait(1))
            self.clock[0] += 2
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(["principal_expired"], errors)
        self.assertEqual(1, self.store.db.execute("SELECT count(*) FROM routes").fetchone()[0])
        self.assertEqual(0, self.store.db.execute("SELECT revoked FROM routes WHERE id=?", (self.route_id,)).fetchone()[0])


class GrokRoutineTests(Fixture, unittest.TestCase):
    def setUp(self):
        self.setup_fixture("grokBot")

    def tearDown(self):
        self.close_fixture()

    def test_conditional_routine_tools_work_without_claiming_events(self):
        self.ready()
        status = self.store.status(self.owner, self.route_id)
        self.assertEqual("manual", status["deliveryMode"])
        self.assertEqual("manualReady", status["state"])
        self.assertFalse(status["automaticDeliveryReady"])
        self.assertEqual(300, status["minimumRoutineIntervalSeconds"])
        receipt = self.send()
        self.assertEqual(receipt["requestID"], self.store.inbox(self.agent, self.route_id)["requests"][0]["requestID"])
        self.store.reply(self.agent, self.route_id, self.generation, receipt["requestID"], "grok-reply", "asynchronous reply")
        self.assertEqual(1, len(self.store.replies(self.owner, self.route_id, self.generation)["replies"]))
        with self.assertRaisesRegex(RelayError, "events_not_established_for_provider"):
            self.store.subscribe(self.agent, self.route_id, "https://callback.example.com/events", SECRET, self.callback)
