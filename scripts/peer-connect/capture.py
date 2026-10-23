#!/usr/bin/env python3
"""Manual real-peer capture; NEVER deploys, runs remote commands or forwards chat."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit

from contract import ContractError, evidence, inputs, prompt, require
from media import screenshots as check_screenshots, video as check_video


class Capture:
    def __init__(self):
        os.umask(0o077)
        self.private = Path(tempfile.mkdtemp(prefix="peer-private-", dir=os.environ["RUNNER_TEMP"]))
        self.artifacts = Path(os.environ["RUNNER_TEMP"]) / "peer-connect-artifacts"
        self.artifacts.mkdir(exist_ok=False)
        self.children = []
        self.recording = None
        self.sensitive = []
        self.manifest = dict(schema_version=1, started_at=time.time(), remote_audit_status="pending-parent-audit",
                             label="SCRIPTED PROVIDER · REAL TRANSPORT · SIMULATOR INSTALL",
                             relay_label="SELF-HOSTED TURN · NOT CLOUDFLARE", modes={})
        self.container = None

    def redact(self, value):
        for secret in sorted(set(self.sensitive), key=len, reverse=True):
            if secret:
                value = value.replace(secret, "[REDACTED]")
        return value

    def run(self, args, log=None, env=None):
        if log:
            with (self.private / log).open("wb") as output:
                result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, env=env)
            text = (self.private / log).read_text(errors="replace")
            (self.artifacts / log).write_text(self.redact(text))
            require(result.returncode == 0, "A local build/test/capture command failed; see redacted logs")
            return ""
        result = subprocess.run(args, capture_output=True, env=env)
        require(result.returncode == 0, "A local simulator command failed (private output withheld)")
        return result.stdout.decode().strip()

    def stop_recording(self):
        if self.recording:
            process = self.recording
            self.recording = None
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def safe_copy(self, source, target):
        # xcresults stay quarantined if any known runtime secret appears inside.
        files = [source] if source.is_file() else [p for p in source.rglob("*") if p.is_file()]
        needles = [value.encode() for value in self.sensitive if value]
        for path in files:
            data = path.read_bytes()
            require(not any(needle in data for needle in needles), "Diagnostic contains runtime secrets; quarantined, not uploaded")
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)

    def finish(self, status):
        self.stop_recording()
        for child in reversed(self.children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        if self.container:
            for name in ("peer-capture-ready.json", "peer-capture-evidence.json"):
                (self.container / "Documents" / name).unlink(missing_ok=True)
        self.manifest.update(finished_at=time.time(), exit_status=status)
        inventory = []
        for path in sorted(self.artifacts.rglob("*")):
            if path.is_file():
                inventory.append(dict(path=str(path.relative_to(self.artifacts)), bytes=path.stat().st_size,
                                      sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        self.manifest["artifacts"] = inventory
        (self.artifacts / "manifest.json").write_text(json.dumps(self.manifest, indent=2) + "\n")
        shutil.rmtree(self.private)

    def execute(self):
        # Remove all credential JSON from inherited environment before launching
        # any Xcode/tool child process. Paths, not secrets, reach XCTest runner.
        public = json.loads(os.environ.pop("PEER_CI_CONFIG_JSON"))
        private = json.loads(os.environ.pop("PEER_CI_SESSION_JSON"))
        key = os.environ.pop("PEER_CI_SSH_KEY")
        nonce = os.environ["PEER_RUN_NONCE"]
        inputs(public, private, nonce)
        self.sensitive = [key]
        for mode in ("direct", "relay"):
            runtime = private[mode]
            link = runtime["pairing_link"]
            self.sensitive.append(link)
            self.sensitive.extend(v for values in parse_qs(urlsplit(link).fragment).values() for v in values)
            for server in runtime["ice_servers"]:
                self.sensitive.extend(str(server[k]) for k in ("username", "credential") if server.get(k))
        self.manifest.update(run_nonce=nonce, app_commit=self.run(["git", "rev-parse", "HEAD"]),
                             github_run_id=os.environ.get("GITHUB_RUN_ID"), github_run_attempt=os.environ.get("GITHUB_RUN_ATTEMPT"))
        require(self.manifest["app_commit"] == public["app_commit"], "Checked-out app differs from approved runtime source")
        require(not self.run(["git", "status", "--porcelain"]), "Approved capture must build a clean exact source commit")
        self.manifest["remote_expected"] = {k: public[k] for k in ("core_commit", "binary_sha256", "contain_id", "container_image_digest")}
        udid = self.run(["python3", "scripts/select-ios-simulator.py"])
        self.manifest["simulator_udid"] = udid
        self.run(["xcodebuild", "-version"], "xcode-version.log")
        # Boot may return nonzero if already booted; bootstatus is the real gate.
        subprocess.run(["xcrun", "simctl", "boot", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        args = ["-project", "TermLLM.xcodeproj", "-scheme", "TermLLM", "-configuration", "Debug", "-sdk", "iphonesimulator",
                "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", str(self.private / "DerivedData"),
                "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="]
        self.run(["xcodebuild", "build-for-testing", *args], "build.log")
        app = self.private / "DerivedData/Build/Products/Debug-iphonesimulator/TermLLM.app"
        require(app.is_dir(), "Real compiled app not found")
        self.manifest["app_binary_sha256"] = hashlib.sha256((app / "TermLLM").read_bytes()).hexdigest()
        # This is an actual recorded SIMULATOR install, not an App Store install.
        install_video = self.private / "simulator-install.mp4"
        self.recording = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", str(install_video)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        require(self.recording.poll() is None, "Install recording failed to start")
        self.run(["xcrun", "simctl", "install", udid, str(app)])
        time.sleep(2)
        require(self.recording.poll() is None, "Install recording ended prematurely")
        self.stop_recording()
        check_video(install_video)
        self.safe_copy(install_video, self.artifacts / install_video.name)
        self.manifest["simulator_install"] = "simctl-install-succeeded-not-app-store"
        self.container = Path(self.run(["xcrun", "simctl", "get_app_container", udid, "com.termllm.app", "data"]))
        ssh = public["ssh"]
        keyfile, known = self.private / "forward-only-key", self.private / "known_hosts"
        keyfile.write_text(key + "\n")
        known.write_text(ssh["known_host"] + "\n")
        # The remote key is restrict + forced stdio command, no SSH TCP
        # forwarding at all. Parent script connects only its fixed broker port.
        ready = self.private / "forward.ready"
        forward = subprocess.Popen(["python3", "scripts/peer-connect/forward_broker.py",
            "--host", ssh["host"], "--user", ssh["user"], "--port", str(ssh["port"]),
            "--key", str(keyfile), "--known-hosts", str(known),
            "--local-port", str(ssh["local_port"]), "--ready-file", str(ready)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(forward)
        for _ in range(100):
            if ready.exists() or forward.poll() is not None:
                break
            time.sleep(0.1)
        require(ready.exists() and forward.poll() is None, "Forced-stdio signalling adapter failed")
        for mode in ("direct", "relay"):
            self.manifest["active_mode"] = mode
            self.mode(mode, nonce, public, private, udid, args)

    def mode(self, mode, nonce, public, private, udid, args):
        docs = self.container / "Documents"
        raw_evidence = docs / "peer-capture-evidence.json"
        raw_evidence.unlink(missing_ok=True)
        config = dict(schema_version=1, run_nonce=nonce, mode=mode, force_relay=mode == "relay",
                      ice_servers=private[mode]["ice_servers"], pairing_link=private[mode]["pairing_link"],
                      prompt=prompt(nonce, mode), node_id=public["node_id"])
        configfile = self.private / f"{mode}-runtime.json"
        configfile.write_text(json.dumps(config))
        require(int(parse_qs(urlsplit(private[mode]["pairing_link"]).query)["exp"][0]) > time.time() + 60, "Pair link expired during build; parent must refresh before capture")
        env = dict(os.environ, TEST_RUNNER_PEER_CAPTURE_CONFIG_PATH=str(configfile))
        result = self.private / f"{mode}.xcresult"
        raw_log = self.private / f"{mode}-test.log"
        with raw_log.open("wb") as log:
            self.recording = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", str(self.private / f"{mode}.mp4")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            test = subprocess.Popen(["xcodebuild", "test-without-building", *args, "-resultBundlePath", str(result),
                "-only-testing:TermLLMUITests/PeerConnectionUITests/testPeerConnectionJourney"], stdout=log, stderr=subprocess.STDOUT, env=env)
            self.children.append(test)
            try:
                # Pair link stays in private JSON/app environment. Native debug
                # launcher opens it through UIApplication, never simctl argv or
                # XCUIApplication.open activities that could log its fragment.
                require(test.wait(timeout=300) == 0, "Actual peer UI journey failed")
                require(self.recording.poll() is None, "Simulator recording stopped before test completed")
            finally:
                if test.poll() is None:
                    test.terminate()
                    test.wait(timeout=15)
                self.stop_recording()
                (self.artifacts / f"{mode}-test.log").write_text(self.redact(raw_log.read_text(errors="replace")))
        summary = json.loads(self.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
        require(summary.get("result") == "Passed" and summary.get("passedTests", 0) >= 1 and summary.get("failedTests", 0) == 0 and summary.get("skippedTests", 0) == 0, "No passing executed peer UI test")
        devices = {entry.get("device", {}).get("deviceId", "").lower() for entry in summary.get("devicesAndConfigurations", [])}
        require(devices == {udid.lower()}, "UI tests ran on a different simulator than recording")
        clean = evidence(json.loads(raw_evidence.read_text()), public, nonce, mode)
        (self.artifacts / f"{mode}-evidence.json").write_text(json.dumps(clean, indent=2) + "\n")
        clean_summary = {key: summary.get(key) for key in ("result", "passedTests", "failedTests", "skippedTests", "totalTestCount")}
        (self.artifacts / f"{mode}-test-summary.json").write_text(json.dumps(clean_summary, indent=2))
        screenshots = self.private / f"{mode}-screenshots"
        self.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(screenshots)])
        check_screenshots(screenshots)
        check_video(self.private / f"{mode}.mp4")
        self.safe_copy(screenshots, self.artifacts / f"{mode}-screenshots")
        self.safe_copy(result, self.artifacts / f"{mode}.xcresult")
        self.safe_copy(self.private / f"{mode}.mp4", self.artifacts / f"{mode}.mp4")
        self.manifest["modes"][mode] = "passed-local-evidence-awaiting-remote-audit"


def main():
    capture = Capture()
    status = 1
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        capture.execute()
        status = 0
    except ContractError as error:
        # ContractError messages are static authored gate descriptions only.
        capture.manifest["failure_gate"] = str(error)
        print("Peer capture failed closed: " + str(error), file=sys.stderr)
    except (Exception, KeyboardInterrupt):
        # Raw tool/JSON/OS exceptions can contain credentials. Never print them.
        capture.manifest["failure_gate"] = "private-input-or-execution-error-details-withheld"
        print("Peer capture failed closed. See sanitized diagnostics and interface blockers.", file=sys.stderr)
    finally:
        try:
            capture.finish(status)
        except Exception:
            status = 1
            shutil.rmtree(capture.private, ignore_errors=True)
            print("Private capture cleanup failed; raw diagnostics withheld.", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
