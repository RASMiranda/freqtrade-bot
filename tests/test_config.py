"""Static checks on the committed config, compose file and env template. No Docker needed."""

import json
import re

import pytest

SECRET_KEYS = ("key", "secret", "password", "token", "jwt_secret_key", "chat_id")


def walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}" if path else k)
    else:
        yield path, node


def test_dry_run_is_true(config):
    assert config["dry_run"] is True


def test_config_has_no_secrets(config):
    for path, value in walk(config):
        leaf = path.rsplit(".", 1)[-1].lower()
        if leaf in SECRET_KEYS:
            assert value in ("", None), f"{path} holds a value; secrets belong in bws or the environment"


def test_config_has_no_live_credentials_text(root):
    text = (root / "user_data" / "config.json").read_text()
    assert not re.search(r'"(password|jwt_secret_key)"\s*:\s*"[^"]', text)


def test_telegram_disabled_by_default(config, root):
    assert config["telegram"]["enabled"] is False
    env_example = (root / ".env.example").read_text()
    assert re.search(r"^FREQTRADE__TELEGRAM__ENABLED=false$", env_example, re.MULTILINE)


def test_env_example_holds_no_secret_values(root):
    for line in (root / ".env.example").read_text().splitlines():
        if line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if re.search(r"(PASSWORD|SECRET|TOKEN|KEY|CHAT_ID)$", name):
            assert value == "", f"{name} must not carry a value in .env.example"


def test_fees_are_not_overridden(config):
    assert "fee" not in config


def test_api_server_inside_container_only(config):
    assert config["api_server"]["enabled"] is True
    assert config["api_server"]["listen_port"] == 8080


@pytest.fixture(scope="module")
def compose(root):
    return (root / "docker-compose.yml").read_text()


def test_api_port_maps_to_loopback_only(compose):
    ports = re.findall(r'^\s*-\s*"?(\d[^"\s]*:\d+(?::\d+)?)"?\s*$', compose, re.MULTILINE)
    assert ports == ["127.0.0.1:8080:8080"], ports


def test_freqtrade_image_pinned_not_floating(compose):
    images = re.findall(r"^\s*image:\s*(\S+)", compose, re.MULTILINE)
    freqtrade = [i for i in images if i.startswith("freqtradeorg/freqtrade:")]
    assert len(freqtrade) == 1, images
    tag = freqtrade[0].split(":", 1)[1]
    assert re.fullmatch(r"\d{4}\.\d{1,2}(\.\d+)?", tag), f"{tag} is not a plain release tag"
    assert tag not in ("stable", "latest")


def test_every_image_has_an_explicit_tag(compose):
    for image in re.findall(r"^\s*image:\s*(\S+)", compose, re.MULTILINE):
        assert ":" in image, image
        assert image.split(":", 1)[1] not in ("latest", "stable"), image


def test_restart_policy_and_autoheal(compose):
    assert "restart: unless-stopped" in compose
    assert "autoheal=true" in compose
    assert re.search(r"willfarrell/autoheal:\d", compose)


def test_stoploss_and_protections_present(root):
    text = (root / "user_data" / "strategies" / "HopperBaseline.py").read_text()
    assert re.search(r"^\s*stoploss\s*=\s*-0\.\d+", text, re.MULTILINE)
    for method in ("MaxDrawdown", "StoplossGuard", "CooldownPeriod"):
        assert f'"{method}"' in text


def test_bands_stop_entry_endpoint(root):
    text = (root / "bands.yaml").read_text()
    assert re.search(r"endpoint:\s*/api/v1/stopentry\b", text)


def test_stopentry_exists_in_pinned_freqtrade():
    api = pytest.importorskip("freqtrade.rpc.api_server.api_trading")
    import inspect

    assert '"/stopentry"' in inspect.getsource(api)


def test_fixture_config_is_valid_json(root):
    json.loads((root / "tests" / "data" / "config.fixture.json").read_text())
