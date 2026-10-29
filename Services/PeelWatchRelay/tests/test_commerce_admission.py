"""Focused coupled effect tests. Only synthetic fixtures; no Apple/provider calls."""
from dataclasses import replace
import base64
import hashlib
from io import BytesIO
import json
import threading
import unittest
from urllib.parse import parse_qs,urlsplit
from uuid import uuid4
from unittest.mock import patch

from peel_watch_relay.broker import RelayError, encode
from peel_watch_relay.commerce_admission import CommerceAdmission,DirectCommerceVerifier,UnavailableCommerce
from peel_watch_relay.auth_crypto import b64
import test_control_plane as cp_fixture


class CommerceFixture:
    def __init__(self,clock):self.clock=clock;self.calls=[];self.hook=None;self.reason="active";self.bad=None
    def verify(self,request):
        self.calls.append(request)
        if self.hook:self.hook()
        if self.bad is not None:return self.bad
        now=self.clock[0]
        result={k:request[k] for k in ("schema","requestId","nonce","pairingId","sessionId")}
        result.update(decision="granted" if self.reason=="active" else "denied",reason=self.reason,verifiedAt=now,expiresAt=now+300 if self.reason=="active" else now)
        if self.reason=="active":result.update(productId="peel.pro.lifetime",ownership="familyShared")
        return result


class CommerceTests(unittest.TestCase):
    def setUp(self):
        self.h=cp_fixture.ControlPlaneTests();self.h.setUp()
        self.mono=[1000.0];self.verifier=CommerceFixture(self.h.clock)
        self.gate=CommerceAdmission(self.h.relay,self.h.control.commerce_context,self.verifier,now=lambda:self.h.clock[0],monotonic=lambda:self.mono[0])
        self.h.relay.commerce=self.gate
        self.session=self.h.session()
        self.env,self.auth=self.h.authenticated(self.session)
    def tearDown(self):self.h.tearDown()
    def proof(self,challenge):
        c=challenge["challenge"]
        return dict(type="proEntitlementProof",**{k:c[k] for k in ("requestId","nonce","pairingId","sessionId")},signedTransactions=["fixture.payload.signature"])
    def grant(self,route=None):
        body={} if route is None else {"routeID":route["route"]["routeID"],"routeGeneration":route["route"]["generation"]}
        challenge=self.gate.challenge(self.auth,body)
        return self.gate.evidence(self.auth,self.proof(challenge))
    def route(self):
        grant=self.grant()
        route=self.h.relay.connect(self.auth.account,self.auth.device,"existing-selected-agent")
        rid=route["route"]["routeID"]
        self.h.relay.db.execute("UPDATE routes SET confirmed=1 WHERE id=?",(rid,))
        self.h.relay.db.execute("INSERT INTO subscriptions VALUES(?,?,?,?,?,?,?,?,?)",("fixture-sub",rid,"https://example.com/callback","whsec_"+base64.b64encode(b"S"*32).decode(),None,None,self.h.clock[0]+1000,1,"fixture"))
        return route,grant
    def plugin(self,route):
        verifier="C"*43
        query={"response_type":"code","client_id":"fixture_chatgpt_client","redirect_uri":"https://chatgpt.com/fixture-callback","state":"fixture_state","code_challenge":b64(hashlib.sha256(verifier.encode()).digest()),"code_challenge_method":"S256","resource":self.h.control.issuer+"/mcp"}
        pending=self.h.oauth.begin(query)
        consent=self.h.oauth.approve(self.env,self.auth,{"oauthTransactionID":pending["transactionID"],"routeID":route["route"]["routeID"]})
        code=parse_qs(urlsplit(consent["authorizationRedirect"]).query)["code"][0]
        token=self.h.oauth.token({"grant_type":"authorization_code","code":code,"code_verifier":verifier,"client_id":query["client_id"],"redirect_uri":query["redirect_uri"],"resource":query["resource"]})
        return self.h.control.authenticate({"PATH_INFO":"/mcp","HTTP_AUTHORIZATION":"Bearer "+token["access_token"]}).account
    def send(self,route):
        r=route["route"]
        return self.h.relay.send(self.auth.account,r["routeID"],r["generation"],str(uuid4()),"fixture message")
    def test_unconfigured_connect_fails_before_route_persistence(self):
        self.h.relay.commerce=UnavailableCommerce()
        with self.assertRaisesRegex(RelayError,"commerce_unavailable"):self.h.relay.connect(self.auth.account,self.auth.device,"existing")
        self.assertEqual(self.h.relay.db.execute("SELECT count(*) FROM routes").fetchone()[0],0)
    def test_exact_initial_binding_moves_to_route_without_deadline_extension(self):
        route,grant=self.route();row=self.h.relay._route(self.auth.account,route["route"]["routeID"])
        permit=self.gate.require_route(self.auth.account,row)
        self.assertEqual(permit.id,grant["leaseID"]);self.assertEqual(permit.wall_expiry,grant["expiresAt"])
        self.assertEqual(row["commerce_enrollment"],self.session["enrollmentID"])
        self.assertEqual(grant["binding"]["phoneKeySHA256"],self.session["phoneKeySHA256"])
        self.assertIsNone(grant["binding"]["routeID"])
        with self.assertRaisesRegex(RelayError,"pro_required"):self.gate.require_connect(self.auth.account,self.auth.device)
    def test_one_use_and_replaced_challenge_do_not_call_verifier(self):
        c=self.gate.challenge(self.auth,{})
        self.gate.evidence(self.auth,self.proof(c))
        with self.assertRaisesRegex(RelayError,"pro_challenge_unavailable"):self.gate.evidence(self.auth,self.proof(c))
        old=self.gate.challenge(self.auth,{});self.gate.challenge(self.auth,{})
        with self.assertRaisesRegex(RelayError,"pro_challenge_unavailable"):self.gate.evidence(self.auth,self.proof(old))
        self.assertEqual(len(self.verifier.calls),1)
    def test_expired_challenge_and_malformed_evidence_do_not_call_verifier(self):
        c=self.gate.challenge(self.auth,{})
        with self.assertRaises(RelayError):self.gate.evidence(self.auth,dict(self.proof(c),signedTransactions=["fake"]))
        self.mono[0]+=31
        with self.assertRaisesRegex(RelayError,"pro_challenge_unavailable"):self.gate.evidence(self.auth,self.proof(c))
        self.assertFalse(self.verifier.calls)
    def test_oversized_or_forged_verdict_never_installs_paid_permit(self):
        c=self.gate.challenge(self.auth,{})
        with self.assertRaises(RelayError):self.gate.evidence(self.auth,dict(self.proof(c),isPro=True))
        self.verifier.bad={"decision":"granted"}
        with self.assertRaisesRegex(RelayError,"commerce_unavailable"):self.gate.evidence(self.auth,self.proof(c))
        self.assertFalse(self.gate.permits)
    def test_late_verification_after_withdraw_or_replacement_is_fenced(self):
        c=self.gate.challenge(self.auth,{})
        self.verifier.hook=lambda:self.gate.withdraw(self.auth,{})
        with self.assertRaisesRegex(RelayError,"pro_challenge_unavailable"):self.gate.evidence(self.auth,self.proof(c))
        self.assertFalse(self.gate.permits)
        self.verifier.hook=None;c=self.gate.challenge(self.auth,{})
        self.verifier.hook=lambda:self.gate.challenge(self.auth,{})
        with self.assertRaisesRegex(RelayError,"pro_challenge_unavailable"):self.gate.evidence(self.auth,self.proof(c))
    def test_late_identity_revocation_never_grants(self):
        c=self.gate.challenge(self.auth,{})
        self.verifier.hook=lambda:self.h.control.revoke(self.env,self.auth)
        with self.assertRaisesRegex(RelayError,"device_authority_changed"):self.gate.evidence(self.auth,self.proof(c))
        self.assertFalse(self.gate.permits)
    def test_cross_enrollment_provider_and_route_generation_are_denied(self):
        route,_=self.route();s=self.h.session(code="other")
        _,other=self.h.authenticated(s)
        with self.assertRaisesRegex(RelayError,"device_access_denied"):self.gate.challenge(other,{"routeID":route["route"]["routeID"],"routeGeneration":route["route"]["generation"]})
        gs=self.h.session(provider="grokBot",code="grok")
        _,grok=self.h.authenticated(gs)
        with self.assertRaisesRegex(RelayError,"pro_required"):self.gate.require_connect(grok.account,grok.device)
        with self.assertRaisesRegex(RelayError,"route_generation_changed"):self.gate.challenge(self.auth,{"routeID":route["route"]["routeID"],"routeGeneration":str(uuid4())})
    def test_dual_clock_expiry_stops_send_before_persistence(self):
        route,_=self.route();self.mono[0]+=301
        with self.assertRaisesRegex(RelayError,"pro_expired"):self.send(route)
        self.assertEqual(self.h.relay.db.execute("SELECT count(*) FROM requests").fetchone()[0],0)
        self.assertEqual(self.h.relay.db.execute("SELECT count(*) FROM deliveries").fetchone()[0],0)
    def test_actual_plugin_oauth_cannot_read_or_reply_after_paid_withdraw(self):
        route,_=self.route();receipt=self.send(route);plugin=self.plugin(route)
        rid=route["route"]["routeID"];gen=route["route"]["generation"]
        self.assertEqual(len(self.h.relay.inbox(plugin,rid)["requests"]),1)
        self.gate.withdraw(self.auth,{})
        for call in [lambda:self.h.relay.inbox(plugin,rid),lambda:self.h.relay.reply(plugin,rid,gen,receipt["requestID"],"r","text"),lambda:self.h.relay.replies(self.auth.account,rid,gen)]:
            with self.assertRaisesRegex(RelayError,"pro_required"):call()
        self.assertIsNone(self.h.relay.db.execute("SELECT reply FROM requests").fetchone()[0])
    def test_old_queued_work_cannot_revive_under_new_paid_grant(self):
        route,_=self.route();self.send(route);self.mono[0]+=301;self.h.clock[0]+=301
        self.grant(route)
        account=self.h.control.delivery_accounts()[0][0]
        class Never:
            def post(self,*a):raise AssertionError("expired queued effect dispatched")
        with self.assertRaisesRegex(RelayError,"pro_required"):self.h.relay.deliver_one(account,route["route"]["routeID"],Never())
        self.assertEqual(self.h.relay.db.execute("SELECT state FROM deliveries").fetchone()[0],"commerce_blocked")
    def test_late_callback_cannot_activate_subscription_after_withdraw(self):
        route,_=self.route();plugin=self.plugin(route);rid=route["route"]["routeID"]
        def verify(*a,**kw):self.gate.withdraw(self.auth,{})
        with patch("peel_watch_relay.broker.verify_callback",side_effect=verify):
            with self.assertRaisesRegex(RelayError,"pro_required"):
                self.h.relay.subscribe(plugin,rid,"https://example.com/new","whsec_"+base64.b64encode(b"T"*32).decode(),object())
        self.assertEqual(self.h.relay.db.execute("SELECT count(*) FROM subscriptions WHERE callback='https://example.com/new' AND active=1").fetchone()[0],0)
    def test_revoke_waits_for_already_admitted_dispatch_then_blocks_next(self):
        route,_=self.route();self.send(route);account=self.h.control.delivery_accounts()[0][0]
        started=threading.Event();release=threading.Event();revoked=threading.Event();errors=[]
        class Held:
            def post(self,*a):started.set();self_outer.assertTrue(release.wait(2));return 200,b""
        self_outer=self
        def delivery():
            try:self.h.relay.deliver_one(account,route["route"]["routeID"],Held())
            except BaseException as e:errors.append(e)
        def revoke():self.gate.withdraw(self.auth,{});revoked.set()
        t=threading.Thread(target=delivery);t.start();self.assertTrue(started.wait(2))
        w=threading.Thread(target=revoke);w.start();self.assertFalse(revoked.wait(.02));release.set();t.join(2);w.join(2)
        self.assertTrue(revoked.is_set());self.assertFalse(errors)
        with self.assertRaisesRegex(RelayError,"pro_required"):self.send(route)
    def test_cleanup_survives_paid_expiry_and_restart_has_no_grant(self):
        route,_=self.route();plugin=self.plugin(route);self.mono[0]+=301
        self.h.relay.unsubscribe(plugin,route["route"]["routeID"],"https://example.com/callback")
        self.h.relay.revoke(self.auth.account,route["route"]["routeID"])
        self.assertEqual(self.gate.withdraw(self.auth,{}),{"withdrawn":True})
        fresh=CommerceAdmission(self.h.relay,self.h.control.commerce_context,self.verifier,now=lambda:self.h.clock[0],monotonic=lambda:self.mono[0])
        with self.assertRaisesRegex(RelayError,"pro_required"):fresh.require_connect(self.auth.account,self.auth.device)
    def test_denial_invalidates_old_permit_and_unavailability_cannot_extend(self):
        route,grant=self.route();row=self.h.relay._route(self.auth.account,route["route"]["routeID"])
        self.verifier.bad={"bad":True}
        with self.assertRaisesRegex(RelayError,"commerce_unavailable"):self.grant(route)
        self.assertEqual(self.gate.require_route(self.auth.account,row).wall_expiry,grant["expiresAt"])
        self.verifier.bad=None;self.verifier.reason="revoked";r=self.grant(route)
        self.assertEqual(r["state"],"denied");self.assertIsNone(r["leaseID"])
        with self.assertRaisesRegex(RelayError,"pro_required"):self.gate.require_route(self.auth.account,row)
    def test_route_grant_uses_paid_remaining_and_keeps_exact17claims(self):
        import jwt
        route,_=self.route();self.mono[0]+=250
        r=self.h.control.route_grant(self.env,self.auth,{"routeID":route["route"]["routeID"],"localEpoch":self.session["localEpoch"]})
        claims=jwt.decode(r["routeGrant"],self.h.broker_key.public_key(),algorithms=["ES256"],audience="com.zephyrstudiosllc.Peel.watchkitapp",options={"verify_exp":False,"verify_iat":False})
        self.assertEqual(len(claims),17);self.assertEqual(claims["exp"]-claims["iat"],50)
    def test_signed_http_endpoints_and_no_client_identity_fields(self):
        def call(path,body):
            result=[];env=self.h.environ(self.session,path,body)
            raw=b"".join(self.h.app(env,lambda status,headers:result.append(status)))
            return result[0],json.loads(raw)
        status,c=call("/v1/native/pro/challenge",{});self.assertEqual(status,"200 OK")
        status,r=call("/v1/native/pro/evidence",self.proof(c));self.assertEqual(r["state"],"verified")
        status,r=call("/v1/native/pro/challenge",{"isPro":True});self.assertNotEqual(status,"200 OK")
        status,r=call("/v1/native/pro/withdraw",{});self.assertEqual(r,{"withdrawn":True})
    def test_direct_adapter_pins_origin_contract_and_rejects_redirect(self):
        class Fake:
            def __init__(self):self.calls=[];self.status=200
            def post(self,url,body,headers):self.calls.append((url,json.loads(body),headers));return self.status,b'{"fixture":true}'
        t=Fake();v=DirectCommerceVerifier("https://commerce.example.com",transport=t)
        self.assertEqual(v.verify({"schema":1}),{"fixture":True})
        self.assertEqual(t.calls[0][0],"https://commerce.example.com/v1/entitlements/verify")
        t.status=302
        with self.assertRaisesRegex(RelayError,"commerce_unavailable"):v.verify({"schema":1})
        for origin in [None,"http://commerce.example.com","https://commerce.example.com/path","https://u:p@commerce.example.com","https://commerce.example.com?x=1","https://commerce.example.invalid"]:
            with self.assertRaises(RelayError):DirectCommerceVerifier(origin,transport=t)

    def test_continuous_renewal_retains_original_queued_permit_deadline(self):
        route,grant=self.route();self.send(route)
        self.h.clock[0]+=100;self.mono[0]+=100
        renewal=self.grant(route)
        self.assertNotEqual(grant["leaseID"],renewal["leaseID"])
        self.assertEqual(self.gate.permits[grant["leaseID"]].wall_expiry,grant["expiresAt"])
        class Accepted:
            calls=0
            def post(self,*a):self.calls+=1;return 202,b""
        transport=Accepted();account=self.h.control.delivery_accounts()[0][0]
        result=self.h.relay.deliver_one(account,route["route"]["routeID"],transport)
        self.assertEqual(result["state"],"accepted");self.assertEqual(transport.calls,1)
    def test_verified_enrollment_denial_closes_its_prior_route_permits(self):
        route,_=self.route();self.verifier.reason="revoked"
        denial=self.grant()
        self.assertEqual(denial["state"],"denied")
        with self.assertRaisesRegex(RelayError,"pro_required"):self.send(route)
