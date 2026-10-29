"""Actual private SQLite/cryptography fixtures for finite first-party continuity."""
import hashlib
from io import BytesIO
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit

import test_control_plane as fixture
from peel_watch_relay.auth_crypto import b64
from peel_watch_relay.broker import RelayError, encode
from peel_watch_relay.control_plane import ControlPlane
from peel_watch_relay.http import strict_json
from peel_watch_relay.plugin_oauth import PluginOAuth
from peel_watch_relay.session_continuity import MAX_APPLICATION_SECONDS


class ContinuityTests(unittest.TestCase):
    setUp = fixture.ControlPlaneTests.setUp
    tearDown = fixture.ControlPlaneTests.tearDown
    request = fixture.ControlPlaneTests.request
    session = fixture.ControlPlaneTests.session
    environ = fixture.ControlPlaneTests.environ
    authenticated = fixture.ControlPlaneTests.authenticated

    def refresh_phone(self, session):
        refresh_session = dict(session, sessionToken=session["refreshToken"])
        environ, _ = self.authenticated(refresh_session, path="/v1/native/renew")
        return self.control.renew(environ)

    def plugin_pair(self, session=None):
        session = session or self.session()
        environ, authority = self.authenticated(session)
        route = self.relay.connect(authority.account, authority.device, "actual-selected-dot")
        verifier = "C"*43
        query = {"response_type":"code", "client_id":"fixture_chatgpt_client",
            "redirect_uri":"https://chatgpt.com/fixture-callback", "state":"fixture_state",
            "code_challenge":b64(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method":"S256",
            "resource":self.control.issuer+"/mcp"}
        pending = self.oauth.begin(query)
        consent = self.oauth.approve(environ, authority,
            {"oauthTransactionID":pending["transactionID"], "routeID":route["route"]["routeID"]})
        code = parse_qs(urlsplit(consent["authorizationRedirect"]).query)["code"][0]
        token = self.oauth.token({"grant_type":"authorization_code", "code":code, "code_verifier":verifier,
            "client_id":query["client_id"], "redirect_uri":query["redirect_uri"], "resource":query["resource"]})
        return session, authority, route, token

    def refresh_plugin(self, token, **changes):
        body = {"grant_type":"refresh_token", "refresh_token":token["refresh_token"],
            "client_id":"fixture_chatgpt_client", "resource":self.control.issuer+"/mcp"}
        body.update(changes)
        return self.oauth.token(body)

    def test_initial_independent_finite_app_deadline_and_only_digests(self):
        session = self.session()
        self.assertEqual(session["applicationSessionExpiresAt"],self.clock[0]+MAX_APPLICATION_SECONDS)
        self.assertEqual(session["refreshExpiresAt"],session["applicationSessionExpiresAt"])
        self.assertNotEqual(session["refreshToken"],session["sessionToken"])
        self.assertLess(session["identity"]["identityExpiresAt"],session["applicationSessionExpiresAt"])
        dump="\n".join(self.control.db.iterdump())
        self.assertNotIn(session["refreshToken"],dump)
        self.assertNotIn(session["sessionToken"],dump)

    def test_expired_access_and_provider_token_do_not_expire_own_app_session(self):
        session=self.session();calls=list(self.provider.calls)
        self.clock[0]+=3601
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(session))
        renewed=self.refresh_phone(session)
        self.assertEqual(renewed["applicationSessionExpiresAt"],session["applicationSessionExpiresAt"])
        self.assertEqual(self.provider.calls,calls)
        _,authority=self.authenticated(dict(session,**renewed))
        self.assertTrue(self.control.current_device(authority.account,authority.device))
        self.assertEqual(len(self.control.delivery_accounts()),1)

    def test_refresh_only_purpose_requires_actual_phone_key_and_exact_body(self):
        session=self.session()
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(session,path="/v1/native/renew"))
        secret=dict(session,sessionToken=session["refreshToken"])
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(secret,path="/v1/watch/send"))
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.authenticate(self.environ(secret,path="/v1/native/renew",key=self.watch))
        environ=self.environ(secret,path="/v1/native/renew")
        environ["peel.raw_body"]=b'{"scope":"agent.reply"}'
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.authenticate(environ)

    def test_rotation_preserves_context_and_does_not_extend_deadline(self):
        session=self.session();self.clock[0]+=1000
        renewed=self.refresh_phone(session)
        for key in ("provider","enrollmentID","phoneDeviceID","accountGeneration","pairingGeneration","localEpoch","phoneKeySHA256","watchKeySHA256","grantedScopes","refreshExpiresAt","applicationSessionExpiresAt"):
            self.assertEqual(renewed[key],session[key],key)
        self.assertNotEqual(renewed["refreshToken"],session["refreshToken"])
        self.assertNotIn("identity",renewed)
        self.assertEqual(renewed["sessionExpiresAt"],self.clock[0]+900)

    def test_used_refresh_with_valid_new_phone_proof_revokes_family(self):
        session=self.session();renewed=self.refresh_phone(session)
        with self.assertRaisesRegex(RelayError,"refresh_token_reused"):
            self.refresh_phone(session)
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(dict(session,**renewed)))

    def test_bearer_only_used_refresh_cannot_revoke_current_family(self):
        session=self.session();renewed=self.refresh_phone(session)
        old=dict(session,sessionToken=session["refreshToken"])
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.authenticate(self.environ(old,path="/v1/native/renew",key=self.watch))
        self.authenticated(dict(session,**renewed))

    def test_absolute_deadline_cannot_be_extended_by_rotation(self):
        session=self.session();deadline=session["applicationSessionExpiresAt"]
        self.clock[0]=deadline-1
        renewed=self.refresh_phone(session)
        self.assertEqual(renewed["sessionExpiresAt"],deadline)
        self.assertEqual(renewed["refreshExpiresAt"],deadline)
        self.clock[0]=deadline
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.refresh_phone(dict(session,**renewed))
        self.assertEqual(self.control.delivery_accounts(),[])

    def test_restart_retains_hashes_deadline_and_rotation_authority(self):
        session=self.session();self.control.close();self.clock[0]+=3601
        from pathlib import Path
        self.control=ControlPlane(Path(self.temp.name)/"auth",self.verifier,issuer="https://relay.example.com",
            principal_key=b"P"*32,signing_key=self.broker_key,signing_kid="fixture-broker-3",now=lambda:self.clock[0])
        self.relay.authority=self.control.current_device;self.control.relay=self.relay
        renewed=self.refresh_phone(session)
        self.assertEqual(renewed["applicationSessionExpiresAt"],session["applicationSessionExpiresAt"])

    def test_legacy_metadata_without_app_session_never_promoted(self):
        session=self.session()
        self.control.db.execute("DELETE FROM auth_application_sessions WHERE enrollment=?",(session["enrollmentID"],))
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.refresh_phone(session)
        self.assertEqual(self.control.db.execute("SELECT count(*) FROM auth_application_sessions").fetchone()[0],0)

    def test_account_and_enrollment_revoke_invalidate_refresh_immediately(self):
        for account_wide in (False,True):
            session=self.session(code="revocation_"+str(account_wide))
            environ,authority=self.authenticated(session)
            self.control.revoke(environ,authority,account_wide=account_wide)
            with self.assertRaisesRegex(RelayError,"authentication_required"):
                self.refresh_phone(session)

    def test_plugin_refresh_preserves_only_current_exact_route_client_and_resource(self):
        session,authority,route,token=self.plugin_pair()
        self.clock[0]+=3601
        renewed=self.refresh_plugin(token)
        self.assertEqual(renewed["application_session_expires_at"],session["applicationSessionExpiresAt"])
        self.assertNotEqual(renewed["refresh_token"],token["refresh_token"])
        plugin=self.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+renewed["access_token"]})
        self.assertEqual(plugin.account.route_ids,frozenset([route["route"]["routeID"]]))
        self.assertIsNone(plugin.device)
        with self.assertRaises(RelayError):self.refresh_plugin(renewed,client_id="other-client")
        with self.assertRaises(RelayError):self.refresh_plugin(renewed,resource="https://other.example/mcp")
        with self.assertRaises(RelayError):self.refresh_plugin(renewed,scope="agent.reply arbitrary")

    def test_plugin_refresh_reuse_revokes_new_access_family(self):
        _,_,_,token=self.plugin_pair();renewed=self.refresh_plugin(token)
        with self.assertRaisesRegex(RelayError,"refresh_token_reused"):self.refresh_plugin(token)
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+renewed["access_token"]})

    def test_route_disconnect_blocks_plugin_refresh_and_cannot_create_new_route(self):
        _,authority,route,token=self.plugin_pair()
        self.relay.revoke(authority.account,route["route"]["routeID"])
        with self.assertRaisesRegex(RelayError,"route_revoked"):self.refresh_plugin(token)
        self.assertEqual(self.relay.db.execute("SELECT count(*) FROM routes").fetchone()[0],1)

    def test_removed_plugin_client_and_revoked_enrollment_cannot_refresh(self):
        session,authority,route,token=self.plugin_pair()
        client=self.oauth.clients.pop("fixture_chatgpt_client")
        with self.assertRaisesRegex(RelayError,"invalid_refresh_grant"):self.refresh_plugin(token)
        self.oauth.clients["fixture_chatgpt_client"]=client
        environ,authority=self.authenticated(session)
        self.control.revoke(environ,authority)
        with self.assertRaisesRegex(RelayError,"authentication_required"):self.refresh_plugin(token)

    def test_rotating_refresh_transaction_rolls_back_when_new_credential_write_fails(self):
        session=self.session();original=self.control._issue
        calls=[0]
        def fail_second(*args,**kwargs):
            calls[0]+=1
            if calls[0]==2:raise RelayError("fixture_storage_failure")
            return original(*args,**kwargs)
        with patch.object(self.control,"_issue",side_effect=fail_second):
            with self.assertRaisesRegex(RelayError,"fixture_storage_failure"):self.refresh_phone(session)
        # Server transaction rolled back; native still MUST treat an uncertain
        # exchange as unusable. This direct fixture call proves storage atomicity.
        renewed=self.refresh_phone(session)
        self.assertNotEqual(renewed["refreshToken"],session["refreshToken"])

    def test_concurrent_phone_rotation_cannot_create_two_live_families(self):
        session=self.session();outcomes=[]
        def run():
            try:outcomes.append(self.refresh_phone(session))
            except RelayError as error:outcomes.append(error.code)
        workers=[threading.Thread(target=run) for _ in range(2)]
        for worker in workers:worker.start()
        for worker in workers:worker.join(5);self.assertFalse(worker.is_alive())
        self.assertEqual(sum(isinstance(o,dict) for o in outcomes),1)
        self.assertIn("refresh_token_reused",outcomes)
        self.assertEqual(self.control.db.execute("SELECT count(*) FROM auth_token_families WHERE revoked=0").fetchone()[0],0)

    def test_oauth_metadata_and_standard_invalid_grant_errors(self):
        self.assertIn("refresh_token",self.oauth.metadata()["grant_types_supported"])
        raw=urlencode({"grant_type":"refresh_token","refresh_token":"unknown","client_id":"fixture_chatgpt_client","resource":self.control.issuer+"/mcp"}).encode()
        environ={"REQUEST_METHOD":"POST","PATH_INFO":"/oauth/token","wsgi.url_scheme":"https","HTTP_HOST":"relay.example.com",
            "CONTENT_TYPE":"application/x-www-form-urlencoded","CONTENT_LENGTH":str(len(raw)),"wsgi.input":BytesIO(raw),"QUERY_STRING":""}
        result={}
        def start(status,headers):result.update(status=status)
        body=strict_json(b"".join(self.app(environ,start)))
        self.assertEqual(result["status"],"400 Bad Request")
        self.assertEqual(body,{"error":"invalid_grant"})

    def test_previously_admitted_phone_authority_cannot_survive_rotation(self):
        session=self.session();_,old=self.authenticated(session)
        route=self.relay.connect(old.account,old.device,"actual-selected-dot")
        renewed=self.refresh_phone(session)
        self.assertFalse(self.control.current_device(old.account,old.device))
        with self.assertRaisesRegex(RelayError,"device_authority_changed"):
            self.relay.assert_device(old.account,old.device,route["route"]["routeID"])
        _,current=self.authenticated(dict(session,**renewed))
        self.assertTrue(self.control.current_device(current.account,current.device))

    def test_previously_admitted_plugin_authority_denied_after_family_reuse(self):
        session,owner,route,token=self.plugin_pair()
        before=self.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+token["access_token"]})
        renewed=self.refresh_plugin(token)
        with self.assertRaisesRegex(RelayError,"device_authority_changed"):
            self.relay.inbox(before.account,route["route"]["routeID"])
        current=self.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+renewed["access_token"]})
        with self.assertRaisesRegex(RelayError,"refresh_token_reused"):self.refresh_plugin(token)
        with self.assertRaisesRegex(RelayError,"device_authority_changed"):
            self.relay.inbox(current.account,route["route"]["routeID"])
