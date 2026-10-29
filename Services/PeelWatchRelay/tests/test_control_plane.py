from commerce_fixture import PositiveCommerceFixture
"""Synthetic cryptographic accounts/peers; no external network or live keys."""
import hashlib
import os
from io import BytesIO
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

import jwt
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from peel_watch_relay.auth_application import AuthenticatedApplication, unique_form
from peel_watch_relay.auth_crypto import b64, enrollment_bytes, fingerprint, request_bytes
from peel_watch_relay.broker import RelayError, RelayStore, encode
from peel_watch_relay.control_plane import ControlPlane, PHONE_SCOPES, AGENT_SCOPES
from peel_watch_relay.http import strict_json
from peel_watch_relay.plugin_oauth import PluginOAuth
from peel_watch_relay.provider_auth import ProviderCodeVerifier, Registration, OPENAI, OPENAI_TOKEN, DISCOVERY, JWKS, X_TOKEN, X_ME


def spki(key):
    return b64(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))


def sign(key, raw):
    return b64(key.sign(raw, ec.ECDSA(hashes.SHA256())))


class ProviderFixture:
    def __init__(self, clock):
        self.clock, self.calls = clock, []
        self.key = ec.derive_private_key(4, ec.SECP256R1())
        self.kid = "fixture-provider-1"
        self.nonce = "N" * 43
        self.overrides = {}
        self.fail_token = False

    def __call__(self, method, url, **kwargs):
        self.calls.append((method, url))
        if url == DISCOVERY:
            return {"issuer": OPENAI, "authorization_endpoint": OPENAI + "/api/accounts/authorize",
                "token_endpoint": OPENAI_TOKEN, "jwks_uri": JWKS, "id_token_signing_alg_values_supported": ["ES256"]}
        if url == JWKS:
            key = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(self.key.public_key()))
            return {"keys": [dict(key, kid=self.kid, alg="ES256", use="sig")]}
        if url == OPENAI_TOKEN:
            if self.fail_token:
                raise RelayError("provider_request_failed")
            claims = {"iss": OPENAI, "aud": "oaiapp_fixture", "sub": "synthetic-provider-subject", "iat": self.clock[0],
                "exp": self.clock[0] + 3600, "nonce": self.nonce}
            claims.update(self.overrides)
            return {"id_token": jwt.encode(claims, self.key, algorithm="ES256", headers={"kid": self.kid})}
        if url == X_TOKEN:
            return {"token_type": "bearer", "access_token": "fixture_only_x_token", "expires_in": 7200, "scope": "users.read tweet.read"}
        if url == X_ME:
            return {"data": {"id": "12345"}}
        raise AssertionError("unexpected provider endpoint")


class RejectWebhook:
    def post(self, *args, **kwargs):
        raise AssertionError("unexpected webhook network")


class ControlPlaneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = [1800000000]
        self.phone = ec.derive_private_key(1, ec.SECP256R1())
        self.watch = ec.derive_private_key(2, ec.SECP256R1())
        self.broker_key = ec.derive_private_key(3, ec.SECP256R1())
        self.provider = ProviderFixture(self.clock)
        registrations = [Registration("dot", "oaiapp_fixture", "peel-fixture://oauth/dot", "fixture-not-live"),
                         Registration("grokBot", "x_fixture", "peel-fixture://oauth/grok", "fixture-not-live")]
        self.verifier = ProviderCodeVerifier(registrations, http=self.provider, now=lambda:self.clock[0])
        self.control = ControlPlane(Path(self.temp.name)/"auth", self.verifier, issuer="https://relay.example.com",
            principal_key=b"P"*32, signing_key=self.broker_key, signing_kid="fixture-broker-3", now=lambda:self.clock[0])
        self.relay = RelayStore(Path(self.temp.name)/"relay", self.control.current_device, now=lambda:self.clock[0])
        self.relay.commerce = PositiveCommerceFixture(lambda:self.clock[0])
        self.oauth = PluginOAuth(self.control, [{"clientID":"fixture_chatgpt_client","redirectURI":"https://chatgpt.com/fixture-callback",
            "provider":"dot","approvalReference":"fixture-only"}])
        self.app = AuthenticatedApplication(self.control,self.relay,self.oauth,RejectWebhook(),native_approval_uri="https://relay.example.com/open-peel")
        self.socket_patch = patch("socket.socket", side_effect=AssertionError("network forbidden in control-plane tests"))
        self.socket_patch.start()

    def tearDown(self):
        self.socket_patch.stop()
        self.relay.close()
        self.control.close()
        self.temp.cleanup()

    def request(self, provider="dot", code="fixture_auth_code"):
        verifier = "V"*43
        registration = self.verifier.registration(provider)
        body = {"provider":provider,"transactionID":str(uuid4()),"clientID":registration.client_id,
            "redirectURI":registration.redirect_uri,"codeChallenge":b64(hashlib.sha256(verifier.encode()).digest()),
            "expectedNonce":self.provider.nonce,"phonePublicKey":spki(self.phone),"watchPublicKey":spki(self.watch),"localEpoch":str(uuid4())}
        response = self.control.challenge(body)
        transcript = dict(body, **response)
        raw = enrollment_bytes(transcript)
        redemption = {"challengeID":response["challengeID"],"code":code,"codeVerifier":verifier,
            "phoneSignature":sign(self.phone,raw),"watchSignature":sign(self.watch,raw)}
        return transcript, redemption

    def session(self, provider="dot", code="fixture_auth_code"):
        _, request = self.request(provider,code)
        return self.control.redeem(request)

    def environ(self, session, path="/v1/watch/connect", body=None, *, nonce=None, key=None):
        raw = encode(body or {})
        timestamp, nonce = str(self.clock[0]), nonce or b64(bytes.fromhex(uuid4().hex+uuid4().hex))
        result = {"REQUEST_METHOD":"POST","PATH_INFO":path,"CONTENT_TYPE":"application/json","CONTENT_LENGTH":str(len(raw)),
            "wsgi.input":BytesIO(raw),"wsgi.url_scheme":"https","HTTP_HOST":"relay.example.com","QUERY_STRING":"",
            "HTTP_AUTHORIZATION":"Bearer "+session["sessionToken"],"HTTP_X_PEEL_ENROLLMENT":session["enrollmentID"],
            "HTTP_X_PEEL_TIMESTAMP":timestamp,"HTTP_X_PEEL_NONCE":nonce,"peel.raw_body":raw}
        result["HTTP_X_PEEL_SIGNATURE"] = sign(key or self.phone,request_bytes(path,raw,timestamp,nonce,session["enrollmentID"]))
        return result

    def authenticated(self, session, path="/v1/watch/connect", body=None):
        environ = self.environ(session,path,body)
        return environ,self.control.authenticate(environ)

    def test_actual_oidc_signature_and_dual_peer_proof_issue_scoped_session(self):
        session = self.session()
        self.assertEqual(session["grantedScopes"],sorted(PHONE_SCOPES))
        self.assertEqual(session["sessionExpiresAt"],self.clock[0]+900)
        self.assertNotEqual(session["accountGeneration"],session["pairingGeneration"])
        self.assertEqual(session["watchKeySHA256"],fingerprint(spki(self.watch)))
        environ,authority = self.authenticated(session)
        self.assertTrue(self.control.current_device(authority.account,authority.device))
        self.assertEqual(authority.account.generation,session["accountGeneration"])
        self.assertNotIn("agent.reply",authority.account.scopes)

    def test_single_use_challenge_and_uncertain_redemption(self):
        _, request = self.request()
        self.provider.fail_token = True
        with self.assertRaisesRegex(RelayError,"provider_request_failed"):
            self.control.redeem(request)
        self.provider.fail_token = False
        with self.assertRaisesRegex(RelayError,"challenge_unavailable"):
            self.control.redeem(request)
        self.assertEqual(sum(url==OPENAI_TOKEN for _,url in self.provider.calls),1)

    def test_invalid_peer_signature_never_redeems_provider_code(self):
        _,request = self.request()
        request["watchSignature"] = request["phoneSignature"]
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.redeem(request)
        self.assertEqual(self.provider.calls,[])

    def test_pkce_mismatch_never_redeems(self):
        _,request=self.request();request["codeVerifier"]="W"*43
        with self.assertRaisesRegex(RelayError,"pkce_mismatch"):
            self.control.redeem(request)
        self.assertFalse(self.provider.calls)

    def test_authentication_rejects_body_mutation_replay_wrongkey_and_plain_bearer(self):
        session=self.session()
        environ=self.environ(session)
        environ["peel.raw_body"]=b'{"changed":true}'
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.authenticate(environ)
        environ=self.environ(session)
        self.control.authenticate(environ)
        with self.assertRaisesRegex(RelayError,"request_proof_reused"):
            self.control.authenticate(environ)
        with self.assertRaisesRegex(RelayError,"invalid_device_proof"):
            self.control.authenticate(self.environ(session,key=self.watch))
        with self.assertRaisesRegex(RelayError,"exact_request_body_required"):
            self.control.authenticate({"PATH_INFO":"/v1/watch/send","HTTP_AUTHORIZATION":"Bearer "+session["sessionToken"]})

    def test_stale_session_and_proof_expiry(self):
        session=self.session();environ=self.environ(session)
        self.clock[0]+=31
        with self.assertRaisesRegex(RelayError,"request_proof_expired"):
            self.control.authenticate(environ)
        self.clock[0]+=900
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(session))

    def test_account_signout_revokes_existing_authority_and_rotates_next_generation(self):
        session=self.session();environ,authority=self.authenticated(session)
        self.control.revoke(environ,authority,account_wide=True)
        self.assertFalse(self.control.current_device(authority.account,authority.device))
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate(self.environ(session))
        replacement=self.session(code="fresh_code")
        self.assertNotEqual(replacement["accountGeneration"],session["accountGeneration"])

    def test_inflight_provider_completion_cannot_resurrect_signout(self):
        session=self.session();environ,authority=self.authenticated(session)
        _,request=self.request(code="late_code")
        original=self.verifier.redeem
        def delayed(*args):
            result=original(*args)
            self.control.revoke(environ,authority,account_wide=True)
            return result
        with patch.object(self.verifier,"redeem",side_effect=delayed):
            with self.assertRaisesRegex(RelayError,"sign_in_interrupted_by_revocation"):
                self.control.redeem(request)

    def test_identity_provider_account_binding_and_real_x_me_route(self):
        session=self.session("grokBot")
        self.assertEqual(session["identity"]["subject"],"12345")
        self.assertEqual(self.provider.calls,[("POST",X_TOKEN),("GET",X_ME)])
        _,authority=self.authenticated(session)
        self.assertEqual(authority.account.identity_method,"x")

    def test_wrong_nonce_audience_issuer_future_iat_and_boolean_exp_rejected(self):
        for key,value in [("nonce","Z"*43),("aud","other_client"),("iss","https://attacker.example"),("iat",self.clock[0]+6),("exp",True)]:
            with self.subTest(key=key):
                self.provider.overrides={key:value}
                _,request=self.request(code="code_"+key)
                with self.assertRaises(RelayError):self.control.redeem(request)

    def test_unfamiliar_jwks_key_refresh_and_no_expired_cache_fallback(self):
        self.session();self.clock[0]+=11
        self.provider.key=ec.derive_private_key(5,ec.SECP256R1());self.provider.kid="fixture-provider-2"
        self.session(code="rotated_code")
        self.assertEqual(sum(url==JWKS for _,url in self.provider.calls),2)
        self.clock[0]+=1801
        original=self.provider.__call__
        def failed(method,url,**kwargs):
            if url==JWKS:raise RelayError("provider_request_failed")
            return original(method,url,**kwargs)
        self.verifier.http=failed
        with self.assertRaisesRegex(RelayError,"invalid_provider_token"):self.session(code="expired_cache_code")

    def test_enrollment_validation_rejects_injected_scalars_alias_uuid_and_same_key(self):
        template,_=self.request()
        base={k:template[k] for k in ("provider","transactionID","clientID","redirectURI","codeChallenge","expectedNonce","phonePublicKey","watchPublicKey","localEpoch")}
        for key,value in [("clientID","oaiapp_fixture\nother"),("transactionID",template["transactionID"].upper()),("expectedNonce","N"*42),("watchPublicKey",base["phonePublicKey"])]:
            with self.subTest(key=key):
                with self.assertRaises(RelayError):self.control.challenge(dict(base,**{key:value}))

    def test_route_grant_requires_confirmation_and_binds_exact_signed_fence(self):
        session=self.session();environ,authority=self.authenticated(session)
        route=self.relay.connect(authority.account,authority.device,"actual-selected-dot")
        request={"routeID":route["route"]["routeID"],"localEpoch":session["localEpoch"]}
        with self.assertRaisesRegex(RelayError,"connection_not_confirmed"):
            self.control.route_grant(environ,authority,request)
        # Synthetic confirmed + unexpired subscription is local fixture state only.
        rid=route["route"]["routeID"]
        self.relay.db.execute("UPDATE routes SET confirmed=1 WHERE id=?",(rid,))
        self.relay.db.execute("INSERT INTO subscriptions VALUES(?,?,?,?,?,?,?,?,?)",("fixture-sub",rid,"https://example.com/callback","fixture",None,None,self.clock[0]+1000,1,"fixture-revision"))
        grant=self.control.route_grant(environ,authority,request)["routeGrant"]
        claims=jwt.decode(grant,self.broker_key.public_key(),algorithms=["ES256"],audience="com.zephyrstudiosllc.Peel.watchkitapp",issuer=self.control.issuer,options={"verify_exp":False,"verify_iat":False})
        self.assertEqual(claims["routeGeneration"],route["route"]["generation"])
        self.assertEqual(claims["localEpoch"],session["localEpoch"])
        self.assertEqual(claims["audWatchKeySHA256"],session["watchKeySHA256"])
        self.assertEqual(claims["exp"]-claims["iat"],300)
        self.assertEqual(jwt.get_unverified_header(grant),{"alg":"ES256","kid":"fixture-broker-3","typ":"peel-route+jwt"})

    def test_plugin_oauth_pkce_callback_resource_and_route_allowlist(self):
        session=self.session();environ,authority=self.authenticated(session)
        route=self.relay.connect(authority.account,authority.device,"actual-selected-dot")
        verifier="C"*43
        query={"response_type":"code","client_id":"fixture_chatgpt_client","redirect_uri":"https://chatgpt.com/fixture-callback",
            "state":"fixture_state","code_challenge":b64(hashlib.sha256(verifier.encode()).digest()),"code_challenge_method":"S256","resource":self.control.issuer+"/mcp"}
        pending=self.oauth.begin(query)
        review=self.oauth.review(authority,{"oauthTransactionID":pending["transactionID"]})
        self.assertEqual(review["clientID"],query["client_id"])
        self.assertEqual(review["resource"],query["resource"])
        consent=self.oauth.approve(environ,authority,{"oauthTransactionID":pending["transactionID"],"routeID":route["route"]["routeID"]})
        from urllib.parse import urlsplit,parse_qs
        callback=parse_qs(urlsplit(consent["authorizationRedirect"]).query)
        self.assertEqual(callback["iss"],[self.control.issuer])
        form={"grant_type":"authorization_code","code":callback["code"][0],"code_verifier":verifier,"client_id":query["client_id"],"redirect_uri":query["redirect_uri"],"resource":query["resource"]}
        with self.assertRaisesRegex(RelayError,"pkce_mismatch"):self.oauth.token(dict(form,code_verifier="D"*43))
        token=self.oauth.token(form)
        plugin=self.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+token["access_token"]})
        self.assertEqual(plugin.account.scopes,AGENT_SCOPES)
        self.assertEqual(plugin.account.route_ids,frozenset([route["route"]["routeID"]]))
        self.assertIsNone(plugin.device)
        with self.assertRaisesRegex(RelayError,"invalid_oauth_grant"):self.oauth.token(form)
        with self.assertRaisesRegex(RelayError,"authentication_required"):
            self.control.authenticate({"PATH_INFO":"/v1/watch/send","HTTP_AUTHORIZATION":"Bearer "+token["access_token"]})
        with self.assertRaises(RelayError):self.oauth.begin(dict(query,redirect_uri="https://attacker.example/callback"))
        with self.assertRaises(RelayError):self.oauth.begin(dict(query,resource="https://other.example/mcp"))

    def test_native_renew_invalidates_old_session_without_changing_generations(self):
        session=self.session();environ,_=self.authenticated(dict(session,sessionToken=session["refreshToken"]),path="/v1/native/renew")
        renewed=self.control.renew(environ)
        with self.assertRaisesRegex(RelayError,"authentication_required"):self.control.authenticate(self.environ(session))
        replacement=dict(session,**renewed)
        _,authority=self.authenticated(replacement)
        self.assertEqual(authority.account.generation,session["accountGeneration"])

    def test_wsgi_exact_https_and_auth_failures_are_bounded(self):
        result={}
        def start(status,headers):result.update(status=status,headers=dict(headers))
        session=self.session();environ=self.environ(session,body={"agent_reference":"chosen-dot"})
        payload=b"".join(self.app(environ,start))
        self.assertEqual(result["status"],"200 OK")
        self.assertIn("route",strict_json(payload))
        environ=self.environ(session);environ["wsgi.url_scheme"]="http"
        self.app(environ,start);self.assertEqual(result["status"],"400 Bad Request")
        environ=self.environ(session);environ["HTTP_AUTHORIZATION"]="Bearer invalid"
        self.app(environ,start)
        self.assertNotEqual(result["status"],"200 OK")
        self.assertEqual(result["headers"]["Cache-Control"],"no-store")

    def test_forms_and_json_duplicate_fields_rejected(self):
        with self.assertRaisesRegex(RelayError,"duplicate_form_field"):unique_form("code=a&code=b")
        with self.assertRaisesRegex(RelayError,"invalid_json"):strict_json(b'{"code":"a","code":"b"}')

    def test_no_default_broker_key_and_no_unverified_request_identity(self):
        with self.assertRaisesRegex(RelayError,"broker_signing_key_required"):
            ControlPlane(Path(self.temp.name)/"bad",self.verifier,issuer=self.control.issuer,principal_key=b"P"*32,signing_key=None,signing_kid="none")
        session=self.session();_,request=self.request(code="extra_identity")
        request["subject"]="attacker_assertion"
        with self.assertRaisesRegex(RelayError,"invalid_parameters"):self.control.redeem(request)

    def test_challenge_expires_and_code_replay_across_new_challenge_rejected(self):
        _,request=self.request();self.clock[0]+=121
        with self.assertRaisesRegex(RelayError,"challenge_unavailable"):self.control.redeem(request)
        self.session(code="one_code")
        _,request=self.request(code="one_code")
        with self.assertRaisesRegex(RelayError,"authorization_code_reused"):self.control.redeem(request)

    def test_concurrent_same_redemption_has_one_provider_exchange(self):
        _,request=self.request();outcomes=[]
        def run():
            try:outcomes.append(self.control.redeem(request))
            except RelayError as error:outcomes.append(error.code)
        workers=[threading.Thread(target=run) for _ in range(2)]
        for worker in workers:worker.start()
        for worker in workers:worker.join(5);self.assertFalse(worker.is_alive())
        self.assertEqual(sum(isinstance(o,dict) for o in outcomes),1)
        self.assertIn("challenge_unavailable",outcomes)
        self.assertEqual(sum(url==OPENAI_TOKEN for _,url in self.provider.calls),1)

    def test_cross_enrollment_route_access_denied(self):
        first=self.session(code="phone_one");_,a=self.authenticated(first)
        route=self.relay.connect(a.account,a.device,"selected-dot")
        second=self.session(code="phone_two");_,b=self.authenticated(second)
        with self.assertRaisesRegex(RelayError,"device_access_denied"):
            self.relay.assert_device(b.account,b.device,route["route"]["routeID"])

    def test_enrollment_revoke_does_not_revoke_other_pair(self):
        first=self.session(code="phone_one");e,a=self.authenticated(first)
        second=self.session(code="phone_two");_,b=self.authenticated(second)
        self.control.revoke(e,a)
        self.assertFalse(self.control.current_device(a.account,a.device))
        self.assertTrue(self.control.current_device(b.account,b.device))

    def test_wsgi_metadata_does_not_create_session_and_rejects_fake_forwarded_scheme(self):
        result={}
        def start(status,headers):result.update(status=status,headers=dict(headers))
        environ={"REQUEST_METHOD":"GET","PATH_INFO":"/.well-known/oauth-authorization-server","wsgi.url_scheme":"https","HTTP_HOST":"relay.example.com"}
        document=strict_json(b"".join(self.app(environ,start)))
        self.assertEqual(document["code_challenge_methods_supported"],["S256"])
        self.assertEqual(self.control.db.execute("SELECT count(*) FROM auth_sessions").fetchone()[0],0)
        environ["wsgi.url_scheme"]="http";environ["HTTP_X_FORWARDED_PROTO"]="https"
        self.app(environ,start);self.assertEqual(result["status"],"400 Bad Request")

    def test_fixed_key_native_interoperability_vector(self):
        # Private scalars1/2/3 are synthetic, public test vectors only. Output
        # contains public keys, signatures and grants, never private-key data.
        challenge={"challengeID":"00000000-0000-4000-8000-000000000001","challenge":b64(bytes(range(32))),
            "provider":"dot","transactionID":"00000000-0000-4000-8000-000000000002",
            "clientID":"oaiapp_fixture","redirectURI":"peel-fixture://oauth/dot",
            "codeChallenge":b64(hashlib.sha256(("V"*43).encode()).digest()),"expectedNonce":"N"*43,
            "phonePublicKey":spki(self.phone),"watchPublicKey":spki(self.watch),
            "localEpoch":"00000000-0000-4000-8000-000000000003","expiresAt":1800000120}
        raw=enrollment_bytes(challenge)
        claims={"iss":"https://relay.example.com","aud":"com.zephyrstudiosllc.Peel.watchkitapp","sub":"principal_fixture",
            "enrollmentID":"00000000-0000-4000-8000-000000000004","phoneDeviceID":"phone_fixture","provider":"dot",
            "accountGeneration":"00000000-0000-4000-8000-000000000005","pairingGeneration":"00000000-0000-4000-8000-000000000006",
            "localEpoch":challenge["localEpoch"],"routeID":"route_fixture","routeGeneration":"00000000-0000-4000-8000-000000000007",
            "audWatchKeySHA256":fingerprint(spki(self.watch)),"phoneKeySHA256":fingerprint(spki(self.phone)),
            "scopes":["watch.read","watch.send"],"iat":1800000000,"exp":1800000300,"jti":"00000000-0000-4000-8000-000000000008"}
        grant=jwt.encode(claims,self.broker_key,algorithm="ES256",headers={"alg":"ES256","kid":"fixture-broker-3","typ":"peel-route+jwt"})
        verified=jwt.decode(grant,self.broker_key.public_key(),algorithms=["ES256"],audience=claims["aud"],issuer=claims["iss"],options={"verify_exp":False,"verify_iat":False})
        self.assertEqual(verified,claims);self.assertEqual(len(claims),17)
        from peel_watch_relay.auth_crypto import verify
        phone_signature,watch_signature=sign(self.phone,raw),sign(self.watch,raw)
        verify(spki(self.phone),phone_signature,raw);verify(spki(self.watch),watch_signature,raw)
        vector={"fixtureOnly":True,"verificationTime":1800000000,"challenge":challenge,
            "enrollmentTranscriptUTF8":raw.decode("ascii"),"enrollmentTranscriptSHA256":hashlib.sha256(raw).hexdigest(),
            "phoneSignatureDER":phone_signature,"watchSignatureDER":watch_signature,
            "brokerPublicKeySPKI":spki(self.broker_key),"brokerKeyID":"fixture-broker-3","routeGrant":grant,"routeClaims":claims}
        output=os.environ.get("PEEL_AUTH_VECTOR_OUTPUT")
        if output:
            path=Path(output)
            if not path.is_absolute() or path.exists():raise AssertionError("fresh explicit vector path required")
            path.write_bytes(encode(vector)+b"\n")


if __name__ == "__main__":
    unittest.main()
