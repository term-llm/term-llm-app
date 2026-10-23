#!/usr/bin/env python3
"""Bounded localhost → SSH forced-stdio broker ONLY. No body/URL/header logs.

Server-side key MUST have restrict,command=<parent-owned fixed broker stdio>.
No -L/-R/-D or remote command is requested. This is NOT a Hub/chat proxy.
"""
import argparse
import asyncio
from pathlib import Path
import signal

MAX_CONNECTIONS = 16
MAX_BYTES = 8 * 1024 * 1024
MAX_AGE = 1800


class LimitExceeded(Exception):
    pass


class Budget:
    def __init__(self, limit=MAX_BYTES):
        self.limit = limit
        self.used = 0

    def consume(self, count):
        self.used += count
        if self.used > self.limit:
            raise LimitExceeded("Signalling byte budget exceeded")


async def pump(reader, writer, budget):
    while True:
        block = await reader.read(16384)
        if not block:
            try:
                writer.write_eof()
            except (AttributeError, NotImplementedError, OSError):
                writer.close()
            return
        budget.consume(len(block))
        writer.write(block)
        await writer.drain()


class BrokerForwarder:
    def __init__(self, command, max_connections=MAX_CONNECTIONS, max_bytes=MAX_BYTES, max_age=MAX_AGE):
        if not 1 <= max_connections <= MAX_CONNECTIONS or not 1 <= max_bytes <= MAX_BYTES or not 0 < max_age <= MAX_AGE:
            raise ValueError("Invalid signalling limits")
        self.command = command
        self.max_connections, self.max_bytes, self.max_age = max_connections, max_bytes, max_age
        self.tasks = set()
        self.children = set()
        self.server = None
        self.closing = False

    async def connect(self, reader, writer):
        if self.closing or len(self.tasks) >= self.max_connections:
            writer.close()
            await writer.wait_closed()
            return
        task = asyncio.current_task()
        self.tasks.add(task)
        process = None
        pumps = []
        try:
            creation = asyncio.create_task(asyncio.create_subprocess_exec(*self.command, stdin=asyncio.subprocess.PIPE,
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL))
            try:
                process = await asyncio.shield(creation)
            except asyncio.CancelledError:
                # Own a child even if cancellation races with process creation.
                process = await creation
                self.children.add(process)
                raise
            self.children.add(process)
            budget = Budget(self.max_bytes)  # Combined byte budget, BOTH directions.
            pumps = [asyncio.create_task(pump(reader, process.stdin, budget)),
                     asyncio.create_task(pump(process.stdout, writer, budget))]
            await asyncio.wait_for(asyncio.gather(*pumps), timeout=self.max_age)
        except (OSError, ConnectionError, LimitExceeded, asyncio.TimeoutError):
            pass  # No request/response body or subprocess error is ever logged.
        finally:
            for pending in pumps:
                pending.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
            if process:
                if process.returncode is None:
                    try:
                        process.terminate()
                    except ProcessLookupError:
                        pass
                try:
                    await asyncio.wait_for(process.wait(), timeout=3)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
                self.children.discard(process)
            self.tasks.discard(task)

    async def close(self):
        self.closing = True
        if self.server:
            self.server.close()
        tasks = list(self.tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if self.server:
            await self.server.wait_closed()


def ssh_command(host, user, port, key, known_hosts):
    return ["ssh", "-F", "/dev/null", "-T", "-p", str(port), "-i", str(key),
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={known_hosts}", "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no", "-o", "RequestTTY=no", "-o", "PermitLocalCommand=no",
            "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR", f"{user}@{host}"]


async def main_async(args):
    forwarder = BrokerForwarder(ssh_command(args.host, args.user, args.port, args.key, args.known_hosts))
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    try:
        forwarder.server = await asyncio.start_server(forwarder.connect, "127.0.0.1", args.local_port)
        Path(args.ready_file).write_text("ready\n")
        try:
            await asyncio.wait_for(stop.wait(), timeout=MAX_AGE)
        except asyncio.TimeoutError:
            pass
    finally:
        await forwarder.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("host", "user", "key", "known-hosts", "ready-file"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--local-port", type=int, default=8769)
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
