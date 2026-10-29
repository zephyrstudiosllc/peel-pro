"""Deployment diagnostics use disposable fixture material, never live config or sockets."""
import json
import sqlite3
from dataclasses import asdict, replace
from pathlib import Path
from unittest.mock import patch

import pytest

from peel_accounts import create_app
from peel_accounts.config import Settings
from peel_accounts.preflight import check, main, native_origin_supported


def configuration(env, tmp_path, **overrides):
    values = asdict(replace(env.settings, public_origin="https://accounts.peelpro.app", **overrides))
    for key, value in values.items():
        if isinstance(value, Path):
            values[key] = str(value)
        elif isinstance(value, tuple):
            values[key] = [str(x) for x in value]
    # Defaults must continue to use fixed team/app values, not operator-chosen audiences.
    values.pop("apple_team_id")
    values.pop("client_id")
    path = tmp_path / "config.json"
    path.write_text(json.dumps(values))
    path.chmod(0o600)
    return path


def test_configuration_check_never_creates_database_or_calls_network(env, tmp_path):
    path = configuration(env, tmp_path)
    database = env.settings.private_dir / "accounts.sqlite3"
    database.unlink()  # Disposable synthetic fixture, not service/user data.
    before = {p: p.read_bytes() for p in tmp_path.rglob("*") if p.is_file()}
    result = check(path)
    assert result["status"] == "configuration_valid"
    assert result["live_acceptance"] == "not_run"
    assert len(result["checks"]) == 6
    assert all(x["status"] == "pass" for x in result["checks"])
    assert not database.exists()
    assert {p: p.read_bytes() for p in tmp_path.rglob("*") if p.is_file()} == before


def test_missing_diagnostic_never_uses_ambient_config(env, tmp_path, monkeypatch):
    path = configuration(env, tmp_path)
    monkeypatch.setenv("PEEL_ACCOUNT_CONFIG", str(path))
    result = check()
    assert result["status"] == "not_ready"
    assert result["checks"] == [{"check": "configuration_file", "status": "fail"}]


@pytest.mark.parametrize("origin", [
    "https://accounts.example.test", "https://127.0.0.1", "https://localhost",
    "https://[::1]", "https://accounts.example.com", "https://accounts.local",
    "https://bad..origin.org", "https://-bad.origin.org", "https://123.456",
    "https://ACCOUNTS.peelpro.app",
])
def test_preflight_cannot_certify_an_origin_native_would_reject(env, tmp_path, origin):
    path = configuration(env, tmp_path)
    value = json.loads(path.read_text())
    value["public_origin"] = origin
    path.write_text(json.dumps(value))
    result = check(path)
    assert result["status"] == "not_ready"
    assert result["checks"][-1]["check"] == "native_origin_policy"
    assert not native_origin_supported(origin)


@pytest.mark.parametrize("origin", [
    "HTTPS://accounts.peelpro.app", "https://accounts.peelpro.app?",
    "https://accounts.peelpro.app#", "https://@accounts.peelpro.app",
    "https://:@accounts.peelpro.app",
    "https://accounts.\npeelpro.app", "https://accounts.peelpro.app/\n",
    "https://\taccounts.peelpro.app",
])
def test_shared_origin_validation_keeps_native_empty_component_semantics(env, tmp_path, origin):
    with pytest.raises(ValueError):
        replace(env.settings, public_origin=origin).validate()
    assert not native_origin_supported(origin)
    path = configuration(env, tmp_path)
    value = json.loads(path.read_text())
    value["public_origin"] = origin
    path.write_text(json.dumps(value))
    result = check(path)
    assert result["status"] == "not_ready"
    assert result["checks"][-1] == {"check": "enabled_private_storage", "status": "fail"}


@pytest.mark.parametrize("origin", [
    "https://accounts.peelpro.app", "https://accounts.peelpro.app/",
    "https://accounts.peelpro.app:443", "https://accounts.peelpro.app:443/",
])
def test_shared_origin_validation_retains_native_optional_slash_and_443(env, origin):
    replace(env.settings, public_origin=origin).validate()
    assert native_origin_supported(origin)


@pytest.mark.parametrize("failure", ["disabled", "apple", "encryption", "lookup"])
def test_precise_fixed_safe_failure_stages(env, tmp_path, failure):
    path = configuration(env, tmp_path, enabled=failure != "disabled")
    if failure == "apple":
        env.settings.apple_key_path.write_bytes(b"SUPER-SECRET-PRIVATE-KEY-WITH-PATH")
    elif failure == "encryption":
        env.settings.encryption_key_path.write_bytes(b"SUPER-SECRET-ENCRYPTION-KEY")
    elif failure == "lookup":
        env.settings.lookup_key_path.write_bytes(b"short")
    result = check(path)
    expected = {"disabled": "enabled_private_storage", "apple": "apple_sign_in_key_format",
                "encryption": "encryption_key_format", "lookup": "lookup_key_length"}
    assert result["checks"][-1] == {"check": expected[failure], "status": "fail"}
    serialized = json.dumps(result)
    assert "SUPER-SECRET" not in serialized
    assert str(tmp_path) not in serialized
    assert "TESTKEY001" not in serialized


@pytest.mark.parametrize("failure", ["world_readable", "symlink", "oversized", "duplicate", "wrong_type", "public"])
def test_private_config_loader_rejects_unsafe_or_ambiguous_files(env, tmp_path, monkeypatch, failure):
    path = configuration(env, tmp_path)
    if failure == "world_readable":
        path.chmod(0o644)
    elif failure == "symlink":
        other = tmp_path / "target.json"
        path.rename(other)
        path.symlink_to(other)
    elif failure == "oversized":
        path.write_text(" " * 16385)
    elif failure == "duplicate":
        path.write_text(path.read_text()[:-1] + ',"enabled":false}')
    elif failure == "wrong_type":
        value = json.loads(path.read_text())
        value["public_origin"] = ["not a URL"]
        path.write_text(json.dumps(value))
    else:
        value = json.loads(path.read_text())
        value["public_webroots"] = [str(tmp_path)]
        path.write_text(json.dumps(value))
    assert check(path)["checks"] == [{"check": "configuration_file", "status": "fail"}]
    monkeypatch.setenv("PEEL_ACCOUNT_CONFIG", str(path))
    response = create_app().test_client().get("/healthz")
    assert response.status_code == 503
    assert response.json == {"error": "account_service_unconfigured"}
    assert str(tmp_path).encode() not in response.data


def test_config_requires_actual_ascii_apple_key_id(env):
    with pytest.raises(ValueError):
        replace(env.settings, apple_key_id="ＡＢＣＤＥＦＧＨＩＪ").validate()


def test_unconfigured_endpoints_never_cache_and_keep_fixed_diagnostic(monkeypatch):
    monkeypatch.delenv("PEEL_ACCOUNT_CONFIG", raising=False)
    client = create_app().test_client()
    for method, path in [("GET", "/healthz"), ("POST", "/v1/challenges"),
                         ("DELETE", "/v1/account"), ("PUT", "/v1/account/preferences")]:
        response = client.open(path, method=method)
        assert response.status_code == 503
        assert response.json == {"error": "account_service_unconfigured"}
        assert response.headers["Cache-Control"] == "no-store"
        assert response.headers["Pragma"] == "no-cache"
        assert response.headers["X-Content-Type-Options"] == "nosniff"
        assert response.headers["Referrer-Policy"] == "no-referrer"
        assert response.headers["Content-Security-Policy"] == "default-src 'none'; frame-ancestors 'none'"


def test_database_initialization_failure_is_fixed_503(env):
    with patch("peel_accounts.app.Store", side_effect=sqlite3.OperationalError("SECRET-DB-PATH")):
        response = create_app(env.settings, env.apple).test_client().get("/healthz")
    assert response.status_code == 503
    assert response.json == {"error": "account_service_unconfigured"}
    assert b"SECRET" not in response.data


def test_cli_missing_config_fixed_json_nonzero(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["preflight"])
    assert main() == 2
    result = json.loads(capsys.readouterr().out)
    assert result["status"] == "not_ready"
    assert result["live_acceptance"] == "not_run"
