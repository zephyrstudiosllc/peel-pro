"""Predefined OAuth 2.1 clients, exact callbacks, resource and route consent.

No arbitrary dynamic registration or URL fetching. Operator copies the actual
MCP client's ID/callback from its management page into reviewed configuration.
Phone approves a transaction through its authenticated signed-request channel;
the browser only receives a code bound to that OAuth client's S256 verifier.
"""
from __future__ import annotations

import hashlib
import hmac
import re
import secrets
from urllib.parse import urlencode, urlsplit
from uuid import uuid4

from .auth_crypto import b64, canonical_uuid, scalar, unb64
from .broker import RelayError
from .control_plane import AGENT_SCOPES
from . import session_continuity as continuity
from .rpc import fields


class PluginOAuth:
    def __init__(self, control, clients):
        self.control = control
        self.clients = {}
        for client in clients:
            fields(client, ("clientID", "redirectURI", "provider", "approvalReference"))
            key = scalar(client["clientID"], 2048)
            parsed = urlsplit(scalar(client["redirectURI"], 2048))
            if client["provider"] not in ("dot", "grokBot") or parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query:
                raise RelayError("invalid_plugin_client")
            scalar(client["approvalReference"], 512)
            if key in self.clients:
                raise RelayError("duplicate_plugin_client")
            self.clients[key] = dict(client)

    def metadata(self):
        origin = self.control.issuer
        return {"issuer": origin, "authorization_endpoint": origin + "/oauth/authorize", "token_endpoint": origin + "/oauth/token",
            "authorization_response_iss_parameter_supported": True, "token_endpoint_auth_methods_supported": ["none"],
            "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"], "scopes_supported": sorted(AGENT_SCOPES)}

    def resource_metadata(self):
        return {"resource": self.control.issuer + "/mcp", "authorization_servers": [self.control.issuer],
                "scopes_supported": sorted(AGENT_SCOPES)}

    def begin(self, query):
        fields(query, ("response_type", "client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "resource"), ("scope",))
        client = self.clients.get(query["client_id"])
        if client is None or query["redirect_uri"] != client["redirectURI"]:
            raise RelayError("unregistered_plugin_client")
        if query["response_type"] != "code" or query["code_challenge_method"] != "S256" or query["resource"] != self.control.issuer + "/mcp":
            raise RelayError("invalid_oauth_request")
        unb64(query["code_challenge"], size=32)
        scalar(query["state"], 512)
        scope = query.get("scope", " ".join(sorted(AGENT_SCOPES)))
        if not isinstance(scope, str) or set(scope.split()) != AGENT_SCOPES or len(scope.split()) != len(AGENT_SCOPES):
            raise RelayError("invalid_plugin_scope")
        with self.control.lock:
            now = self.control._time()
            self.control._cleanup(now)
            if self.control.db.execute("SELECT count(*) FROM auth_plugin_transactions").fetchone()[0] >= 256:
                raise RelayError("oauth_capacity")
            transaction = str(uuid4())
            self.control.db.execute("INSERT INTO auth_plugin_transactions(id,client_id,redirect_uri,state,challenge,scope,resource,expires) VALUES(?,?,?,?,?,?,?,?)",
                (transaction, client["clientID"], client["redirectURI"], query["state"], query["code_challenge"], scope, query["resource"], now + 300))
            return {"transactionID": transaction, "provider": client["provider"], "clientID": client["clientID"],
                "redirectURI": client["redirectURI"], "requestedScopes": sorted(AGENT_SCOPES), "expiresAt": now + 300,
                "state": "approveInPeel", "approvalRequest": {"oauthTransactionID": transaction}}

    def approve(self, environ, authority, body):
        fields(body, ("oauthTransactionID", "routeID"))
        transaction = canonical_uuid(body["oauthTransactionID"])
        self.control.relay.assert_device(authority.account, authority.device, body["routeID"])
        with self.control.lock:
            now = self.control._time()
            row = self.control.db.execute("SELECT * FROM auth_plugin_transactions WHERE id=?", (transaction,)).fetchone()
            if row is None or row["consumed"] or row["code_digest"] or row["expires"] <= now:
                raise RelayError("oauth_transaction_unavailable")
            client = self.clients.get(row["client_id"])
            if client is None or client["provider"] != authority.account.provider:
                raise RelayError("plugin_provider_mismatch")
            code = secrets.token_urlsafe(32)
            self.control.db.execute("UPDATE auth_plugin_transactions SET code_digest=?,enrollment=?,route=?,expires=? WHERE id=?",
                (hashlib.sha256(code.encode()).hexdigest(), environ["peel.auth_enrollment"], body["routeID"], now + 60, transaction))
            # Only authenticated native owner gets this URL; no browser poll can steal it.
            redirect = row["redirect_uri"] + "?" + urlencode({"code": code, "state": row["state"], "iss": self.control.issuer})
            return {"authorizationRedirect": redirect, "expiresAt": now + 60}

    def review(self, authority, body):
        fields(body, ("oauthTransactionID",))
        transaction = canonical_uuid(body["oauthTransactionID"])
        with self.control.lock:
            now = self.control._time()
            row = self.control.db.execute("SELECT * FROM auth_plugin_transactions WHERE id=?", (transaction,)).fetchone()
            if row is None or row["consumed"] or row["code_digest"] or row["expires"] <= now:
                raise RelayError("oauth_transaction_unavailable")
            client = self.clients.get(row["client_id"])
            if client is None or client["provider"] != authority.account.provider:
                raise RelayError("plugin_provider_mismatch")
            return {"oauthTransactionID": transaction, "provider": client["provider"], "clientID": row["client_id"],
                "redirectURI": row["redirect_uri"], "resource": row["resource"],
                "requestedScopes": sorted(AGENT_SCOPES), "expiresAt": row["expires"]}

    def token(self, form):
        if isinstance(form, dict) and form.get("grant_type") == "refresh_token":
            return self.refresh(form)
        fields(form, ("grant_type", "code", "code_verifier", "client_id", "redirect_uri", "resource"))
        if form["grant_type"] != "authorization_code" or form["resource"] != self.control.issuer + "/mcp":
            raise RelayError("invalid_oauth_grant")
        unb64(form["code"], size=32)
        verifier = form["code_verifier"]
        if not isinstance(verifier, str) or not re.fullmatch(r"[A-Za-z0-9._~-]{43,128}", verifier):
            raise RelayError("invalid_pkce_verifier")
        digest = hashlib.sha256(form["code"].encode()).hexdigest()
        with self.control.lock:
            now = self.control._time()
            row = self.control.db.execute("SELECT * FROM auth_plugin_transactions WHERE code_digest=?", (digest,)).fetchone()
            if row is None or row["consumed"] or row["expires"] <= now or row["client_id"] != form["client_id"] or row["redirect_uri"] != form["redirect_uri"]:
                raise RelayError("invalid_oauth_grant")
            if not hmac.compare_digest(row["challenge"], b64(hashlib.sha256(verifier.encode()).digest())):
                raise RelayError("pkce_mismatch")
            client = self.clients.get(form["client_id"])
            enrollment = self.control.db.execute("""SELECT e.*,a.generation AS current_generation,a.revoked AS account_revoked,
                app.expires AS application_expires,app.revoked AS application_revoked FROM auth_enrollments e
                JOIN auth_accounts a ON a.principal=e.principal JOIN auth_application_sessions app ON app.enrollment=e.id WHERE e.id=?""", (row["enrollment"],)).fetchone()
            if (client is None or enrollment is None or client["provider"] != enrollment["provider"]
                    or client["redirectURI"] != row["redirect_uri"] or enrollment["revoked"] or enrollment["account_revoked"]
                    or enrollment["application_revoked"] or enrollment["application_expires"] <= now
                    or enrollment["account_generation"] != enrollment["current_generation"]):
                raise RelayError("enrollment_changed")
            self.control.db.execute("BEGIN IMMEDIATE")
            try:
                credentials = continuity.create_family(self.control, row["enrollment"], kind="plugin",
                    client_id=form["client_id"], resource=form["resource"], route=row["route"], scopes=AGENT_SCOPES)
                self.control.db.execute("UPDATE auth_plugin_transactions SET consumed=1 WHERE id=?", (row["id"],))
                self.control.db.execute("COMMIT")
            except BaseException:
                self.control.db.execute("ROLLBACK")
                raise
            return self._token_response(credentials, form["resource"])

    def _token_response(self, credentials, resource):
        now = self.control._time()
        return {"access_token": credentials["sessionToken"], "token_type": "Bearer",
            "expires_in": credentials["sessionExpiresAt"] - now, "scope": " ".join(sorted(AGENT_SCOPES)), "resource": resource,
            "refresh_token": credentials["refreshToken"], "refresh_token_expires_in": credentials["refreshExpiresAt"] - now,
            "application_session_expires_at": credentials["applicationSessionExpiresAt"]}

    def refresh(self, form):
        fields(form, ("grant_type", "refresh_token", "client_id", "resource"), ("scope",))
        if form["grant_type"] != "refresh_token" or form["resource"] != self.control.issuer + "/mcp":
            raise RelayError("invalid_refresh_grant")
        client = self.clients.get(form["client_id"])
        if client is None:
            raise RelayError("invalid_refresh_grant")
        if "scope" in form and (not isinstance(form["scope"], str) or set(form["scope"].split()) != AGENT_SCOPES):
            raise RelayError("invalid_plugin_scope")
        # Preserve broker -> authority lock order and prevent route revoke from
        # interleaving between current-route validation and atomic rotation.
        with self.control.relay.lock, self.control.lock:
            row = self.control._session(form["refresh_token"], kind="pluginRefresh", allow_used_refresh=True)
            if row["provider"] != client["provider"]:
                raise RelayError("plugin_provider_mismatch")
            from .broker import Account
            from .http import strict_json
            routes = strict_json(row["routes"])
            if len(routes) != 1:
                raise RelayError("invalid_refresh_grant")
            account = Account(row["principal"], row["provider"], "chatGPT" if row["provider"] == "dot" else "x",
                row["account_generation"], AGENT_SCOPES, row["application_expires"], frozenset(routes))
            self.control.relay._route(account, routes[0])
            credentials = continuity.rotate(self.control, row["digest"], kind="plugin", client_id=form["client_id"], resource=form["resource"])
            return self._token_response(credentials, form["resource"])
