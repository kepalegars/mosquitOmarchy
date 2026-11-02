import importlib.util
import json
import pathlib
import urllib.error
import unittest
from importlib.machinery import SourceFileLoader
from unittest.mock import patch


AGENT_PATH = pathlib.Path(__file__).parents[1] / "omarchy-vm-clipboard-agent"
SPEC = importlib.util.spec_from_loader(
    "clipboard_agent", SourceFileLoader("clipboard_agent", str(AGENT_PATH))
)
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


class ClipboardAgentTest(unittest.TestCase):
    def test_poll_host_retries_temporary_disconnect(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self):
                return json.dumps({"rev": 0, "text": ""}).encode()

        class StopPolling(Exception):
            pass

        calls = 0

        def urlopen(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise urllib.error.URLError("temporary disconnect")
            if calls == 2:
                return Response()
            raise StopPolling

        agent.AGENT.rev = 0
        with patch.object(agent.urllib.request, "urlopen", side_effect=urlopen), \
                patch.object(agent.time, "sleep"):
            with self.assertRaises(StopPolling):
                agent.poll_host()
        self.assertEqual(calls, 3)


if __name__ == "__main__":
    unittest.main()
