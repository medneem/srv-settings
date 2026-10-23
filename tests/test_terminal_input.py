"""Real UTF-8 terminal editing regression tests, isolated in a PTY (no system changes)."""
import errno
import os
import pty
import select
import shlex
import signal
import time
import unittest
from pathlib import Path

COMMON = Path(__file__).resolve().parents[1] / "modules" / "common.sh"


def terminal_session(body, keystrokes, prompt=b"EDIT> "):
    """Reproduce terminals whose line discipline has IUTF8 disabled."""
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["LC_ALL"] = "C.UTF-8"
        env["LANG"] = "C.UTF-8"
        command = (
            "set -eu; stty -iutf8; "
            f"source {shlex.quote(str(COMMON))}; {body}"
        )
        os.execvpe("bash", ["bash", "-c", command], env)

    output = bytearray()
    sent = False
    status = None
    deadline = time.monotonic() + 6
    try:
        while time.monotonic() < deadline:
            if not sent and prompt in output:
                os.write(fd, keystrokes)
                sent = True
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as ex:
                    if ex.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output.extend(chunk)
            state, code = os.waitpid(pid, os.WNOHANG)
            if state == pid:
                status = code
                break
        if status is None:
            state, status = os.waitpid(pid, os.WNOHANG)
            if state == 0:
                os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
        return sent, os.waitstatus_to_exitcode(status), bytes(output)
    finally:
        os.close(fd)


class TestTerminalEditing(unittest.TestCase):
    def verify(self, body, text, expected):
        # Each Cyrillic letter is two UTF-8 bytes. Without a Unicode-aware
        # editor, three Backspaces delete three BYTES, not three letters.
        keys = text.encode("utf-8") + b"\x7f" * len(text) + expected + b"\r"
        sent, code, output = terminal_session(body, keys)
        self.assertTrue(sent, output.decode("utf-8", errors="replace"))
        self.assertEqual(code, 0, output.decode("utf-8", errors="replace"))
        self.assertIn(b"RESULT=" + expected, output)

    def test_confirmation_accepts_latin_after_erasing_cyrillic(self):
        self.verify(
            "if confirm 'EDIT> '; then echo RESULT=y; else echo RESULT=NO; fi",
            "нуу",
            b"y",
        )

    def test_ask_port_accepts_digits_after_erasing_cyrillic(self):
        self.verify(
            "ask 'EDIT>' 22; printf 'RESULT=%s\n' \"$REPLY\"",
            "абв",
            b"2203",
        )

    def test_menu_input_accepts_digit_after_erasing_cyrillic(self):
        self.verify(
            "read_input 'EDIT> ' selection; printf 'RESULT=%s\n' \"$selection\"",
            "йцу",
            b"3",
        )


if __name__ == "__main__":
    unittest.main()
