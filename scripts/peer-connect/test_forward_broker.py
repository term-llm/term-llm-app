import asyncio
import sys
import unittest

from forward_broker import BrokerForwarder, Budget, LimitExceeded, ssh_command

ECHO = [sys.executable, "-u", "-c", "import os\nwhile True:\n b=os.read(0,4096)\n if not b: break\n os.write(1,b)"]


class ForwarderTests(unittest.IsolatedAsyncioTestCase):
    async def start(self, **kwargs):
        forward = BrokerForwarder(ECHO, **kwargs)
        forward.server = await asyncio.start_server(forward.connect, "127.0.0.1", 0)
        self.addAsyncCleanup(forward.close)
        return forward, forward.server.sockets[0].getsockname()[1]

    async def test_bidirectional_bytes_and_cleanup(self):
        forward, port = await self.start()
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"opaque-signalling-only")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(len(b"opaque-signalling-only")), 2), b"opaque-signalling-only")
        children = list(forward.children)
        self.assertEqual(len(children), 1)
        await forward.close()
        self.assertTrue(all(child.returncode is not None for child in children))
        self.assertFalse(forward.children)
        writer.close()
        await writer.wait_closed()

    async def test_combined_budget_closes_connection(self):
        forward, port = await self.start(max_bytes=8)
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"123456789")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"")
        writer.close()
        await writer.wait_closed()

    async def test_connection_cap(self):
        forward, port = await self.start(max_connections=1)
        first_reader, first_writer = await asyncio.open_connection("127.0.0.1", port)
        first_writer.write(b"x")
        await first_writer.drain()
        self.assertEqual(await asyncio.wait_for(first_reader.readexactly(1), 2), b"x")
        second_reader, second_writer = await asyncio.open_connection("127.0.0.1", port)
        self.assertEqual(await asyncio.wait_for(second_reader.read(), 2), b"")
        self.assertEqual(len(forward.children), 1)
        for writer in (first_writer, second_writer):
            writer.close()
            await writer.wait_closed()

    async def test_age_cap(self):
        forward, port = await self.start(max_age=0.05)
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"")
        writer.close()
        await writer.wait_closed()


class PolicyTests(unittest.TestCase):
    def test_budget_combines_directions(self):
        budget = Budget(8)
        budget.consume(4)
        budget.consume(4)
        with self.assertRaises(LimitExceeded):
            budget.consume(1)

    def test_no_tcp_forwarding_or_remote_command(self):
        command = ssh_command("owned.invalid", "task-user", 22, "/private/key", "/private/hosts")
        self.assertEqual(command[-1], "task-user@owned.invalid")
        self.assertIn("ClearAllForwardings=yes", command)
        self.assertIn("StrictHostKeyChecking=yes", command)
        self.assertNotIn("-N", command)  # Need a session for the fixed forced command.
        for flag in ("-L", "-R", "-D", "-A"):
            self.assertNotIn(flag, command)


if __name__ == "__main__":
    unittest.main()
