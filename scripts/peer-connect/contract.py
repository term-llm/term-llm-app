"""Peer capture v1 adapter: inputs private; artifacts rebuilt from allowlists."""
import hashlib
import json
import re
import time
from urllib.parse import parse_qs, urlsplit


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)  # Never interpolate secrets or raw input.


def text(value, pattern, message):
    require(isinstance(value, str) and re.fullmatch(pattern, value), message)
    return value


def prompt(nonce, mode):
    return f"PEER-CAPTURE {nonce} {mode}: describe this test."


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def inputs(public, private, nonce, now=None):
    now = time.time() if now is None else now
    require(public.get("schema_version") == 1 and private.get("schema_version") == 1, "Unsupported adapter schema")
    text(nonce, r"[A-Za-z0-9_-]{16,80}", "Invalid run nonce")
    require(private.get("run_nonce") == nonce, "Runtime does not match dispatch nonce")
    require(now + 60 < private.get("expires_at", 0) <= now + 3600, "Runtime must expire in 1–60 minutes")
    for key in ("core_commit", "app_commit"):
        text(public.get(key), r"[0-9a-f]{40}", "Exact source SHA required")
    text(public.get("binary_sha256"), r"[0-9a-f]{64}", "Remote binary SHA256 required")
    text(public.get("container_image_digest"), r"sha256:[0-9a-f]{64}", "Container image digest required")
    text(public.get("contain_id"), r"[A-Za-z0-9_.-]{1,100}", "Owned contain identity required")
    ssh = public.get("ssh", {})
    for key in ("host", "user"):
        text(ssh.get(key), r"[A-Za-z0-9][A-Za-z0-9_.-]{0,200}", "Invalid SSH endpoint")
    for key in ("port", "local_port", "broker_port"):
        minimum = 1 if key == "port" else 1024
        require(type(ssh.get(key)) is int and minimum <= ssh[key] <= 65535, "Invalid SSH port")
    require(ssh["broker_port"] == 8769, "Parent forced-stdio script must target the agreed fixed broker port 8769")
    known = ssh.get("known_host", "")
    require(isinstance(known, str) and "\n" not in known and len(known.split()) == 3, "One pinned SSH host key required")
    expected_host = ssh["host"] if ssh["port"] == 22 else f'[{ssh["host"]}]:{ssh["port"]}'
    require(known.split()[0] == expected_host and known.split()[1] in ("ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"), "Pinned key endpoint mismatch")
    text(public.get("node_id"), r"[A-Za-z0-9_-]{1,64}", "Real Hub node ID required")
    for mode in ("direct", "relay"):
        runtime = private.get(mode, {})
        link = urlsplit(runtime.get("pairing_link", ""))
        require(link.scheme == "term-llm-pair" and link.netloc == "v1", "Actual v1 pairing link required")
        query = parse_qs(link.query)
        broker = urlsplit(query.get("broker", [""])[0])
        require(broker.scheme == "http" and broker.hostname == "localhost" and broker.port == ssh["local_port"] and broker.path in ("", "/") and not broker.query and not broker.fragment and not broker.username, "Pair broker must use ONLY the configured signalling forward")
        require(float(query.get("exp", [0])[0]) > now + 60, "Pairing link expires too soon")
        fragment = parse_qs(link.fragment)
        require(bool(fragment.get("ps")) and bool(fragment.get("cap")), "Private pairing capabilities missing")
        servers = runtime.get("ice_servers", [])
        require(isinstance(servers, list) and bool(servers), "Explicit ICE server list required")
        for server in servers:
            require(isinstance(server.get("urls"), list) and bool(server["urls"]), "Invalid ICE server URLs")
            for url in server["urls"]:
                require(isinstance(url, str) and url.startswith(("stun:", "turn:", "turns:")) and (url.startswith("stun:") or "cloudflare" not in url.lower()), "Only explicitly labelled self-hosted ICE servers accepted")
        if mode == "relay":
            require(any(any(url.startswith(("turn:", "turns:")) for url in server["urls"]) and server.get("username") and server.get("credential") for server in servers), "Self-hosted TURN credentials required")
    return public, private


def evidence(raw, public, nonce, mode):
    require(raw.get("schema_version") == 1 and raw.get("run_nonce") == nonce and raw.get("mode") == mode, "Evidence run/mode mismatch")
    require(raw.get("transport") == "webrtc-datachannel" and raw.get("provider_label") == "SCRIPTED PROVIDER", "Actual labelled WebRTC transport required")
    require(raw.get("force_relay") is (mode == "relay"), "ICE policy does not match requested mode")
    require(raw.get("hub_returned") is True, "Native Hub return not observed")
    result = dict(schema_version=1, run_nonce=nonce, mode=mode, transport="webrtc-datachannel",
                  provider_label="SCRIPTED PROVIDER", force_relay=mode == "relay", hub_returned=True,
                  turn_provider="self-hosted" if mode == "relay" else "not-selected",
                  remote_audit_status="pending-parent-audit")
    chat = raw.get("chat", {})
    for key in ("session_id", "response_id"):
        text(chat.get(key), r"[A-Za-z0-9_.:-]{1,160}", "Real session/response identifiers required")
    require(chat.get("prompt_sha256") == digest(prompt(nonce, mode)), "Actual request prompt hash mismatch")
    text(chat.get("assistant_sha256"), r"[0-9a-f]{64}", "Completed assistant hash required")
    require(chat.get("completed") is True, "Assistant response not completed")
    require(type(chat.get("sse_event_count")) is int and chat["sse_event_count"] >= 2 and type(chat.get("text_delta_count")) is int and chat["text_delta_count"] >= 1, "Per-response SSE stream evidence required")
    require(chat.get("sse_response_id") == chat["response_id"], "SSE evidence must correlate to the actual response")
    start, end = chat.get("request_started_at"), chat.get("response_completed_at")
    require(type(start) in (int, float) and type(end) in (int, float) and start <= end <= time.time() + 120 and time.time() - start < 3600, "Invalid response timestamps")
    result["chat"] = {key: chat[key] for key in ("session_id", "response_id", "prompt_sha256", "assistant_sha256", "sse_response_id", "sse_event_count", "text_delta_count", "request_started_at", "response_completed_at", "completed")}
    samples = {}
    counters = ("bytes_sent", "bytes_received", "data_channel_bytes_sent", "data_channel_bytes_received", "data_channel_messages_sent", "data_channel_messages_received")
    for name in ("before_chat", "after_chat"):
        sample = raw.get(name, {})
        text(sample.get("selected_pair_id"), r"[A-Za-z0-9_+./:-]{1,160}", "Selected ICE pair required")
        for key in ("local_type", "remote_type"):
            require(sample.get(key) in ("host", "srflx", "prflx", "relay"), "Selected candidate types required")
        require(sample.get("protocol") in ("udp", "tcp"), "Selected transport protocol required")
        if mode == "direct":
            require("relay" not in (sample["local_type"], sample["remote_type"]), "Direct trial selected a relay")
        else:
            require(sample["local_type"] == "relay", "Forced-relay trial did not select local TURN relay")
        for key in counters:
            require(type(sample.get(key)) is int and sample[key] >= 0, "Actual transport counters required")
        samples[name] = {key: sample[key] for key in ("selected_pair_id", "local_type", "remote_type", "protocol", *counters)}
    require(samples["before_chat"]["selected_pair_id"] == samples["after_chat"]["selected_pair_id"], "ICE pair changed during measured request; rerun for unambiguous deltas")
    for key in counters:
        require(samples["after_chat"][key] > samples["before_chat"][key], "Chat must increase selected-pair AND DataChannel byte/message counters")
    result.update(samples)
    result["remote_expected"] = {key: public[key] for key in ("core_commit", "binary_sha256", "container_image_digest", "contain_id")}
    # Do not copy unknown fields: SDP, raw URLs, ICE addresses and secrets never
    # enter artifacts even if a native diagnostic exporter accidentally adds them.
    return result
