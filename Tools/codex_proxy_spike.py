#!/usr/bin/env python3
"""Read-only Codex app-server proxy diagnostic.

This intentionally implements only enough RFC 6455 to validate the SSH/stdin
proxy before the Swift client is run. It never resumes a thread or answers a
server-originated request.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import select
import shlex
import struct
import subprocess
import sys
import time
from typing import Any


ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_MESSAGE_BYTES = 16 * 1024 * 1024


class SpikeError(RuntimeError):
    pass


def read_exact(stream: Any, count: int, timeout: float = 10.0) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while len(output) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SpikeError(f"timed out waiting for {count} bytes")
        readable, _, _ = select.select([stream], [], [], remaining)
        if not readable:
            continue
        chunk = os.read(stream.fileno(), count - len(output))
        if not chunk:
            raise SpikeError("proxy closed stdout")
        output.extend(chunk)
    return bytes(output)


def read_http_headers(stream: Any) -> bytes:
    output = bytearray()
    while b"\r\n\r\n" not in output:
        output.extend(read_exact(stream, 1))
        if len(output) > 64 * 1024:
            raise SpikeError("HTTP upgrade response headers are too large")
    return bytes(output)


def send_frame(stream: Any, opcode: int, payload: bytes) -> None:
    if len(payload) > MAX_MESSAGE_BYTES:
        raise SpikeError("outbound message is too large")
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length <= 0xFFFF:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    mask = os.urandom(4)
    header.extend(mask)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    stream.write(header + masked)
    stream.flush()


def receive_message(stdin: Any, stdout: Any) -> dict[str, Any]:
    fragments = bytearray()
    started = False
    while True:
        first, second = read_exact(stdout, 2)
        final = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(stdout, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(stdout, 8))[0]
        if length > MAX_MESSAGE_BYTES:
            raise SpikeError("inbound WebSocket message is too large")
        mask = read_exact(stdout, 4) if masked else b""
        payload = read_exact(stdout, length)
        if mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))

        if opcode == 0x8:
            raise SpikeError("server sent a WebSocket close frame")
        if opcode == 0x9:
            send_frame(stdin, 0xA, payload)
            continue
        if opcode == 0xA:
            continue
        if opcode == 0x1:
            if started:
                raise SpikeError("unexpected new text frame during fragmentation")
            started = True
            fragments.extend(payload)
        elif opcode == 0x0 and started:
            fragments.extend(payload)
        else:
            raise SpikeError(f"unsupported WebSocket opcode {opcode}")

        if len(fragments) > MAX_MESSAGE_BYTES:
            raise SpikeError("fragmented WebSocket message is too large")
        if final:
            try:
                decoded = json.loads(fragments.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise SpikeError(f"invalid JSON text frame: {error}") from error
            if not isinstance(decoded, dict):
                raise SpikeError("expected a JSON object")
            return decoded


def send_json(stream: Any, message: dict[str, Any]) -> None:
    send_frame(
        stream,
        0x1,
        json.dumps(message, separators=(",", ":")).encode("utf-8"),
    )


def request(
    stdin: Any,
    stdout: Any,
    request_id: int,
    method: str,
    params: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], list[str]]:
    message: dict[str, Any] = {"id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    send_json(stdin, message)
    notifications: list[str] = []
    while True:
        response = receive_message(stdin, stdout)
        if response.get("id") == request_id:
            if "error" in response:
                raise SpikeError(f"{method} failed: {response['error']}")
            return response, notifications
        incoming_method = response.get("method")
        if isinstance(incoming_method, str):
            notifications.append(incoming_method)
            if "id" in response:
                raise SpikeError(
                    f"server request {incoming_method!r} was received; refusing to answer"
                )


def remote_command(codex_path: str, start_daemon: bool) -> str:
    quoted = shlex.quote(codex_path)
    if start_daemon:
        return (
            f"{quoted} app-server daemon start 1>&2"
            f" && exec {quoted} app-server proxy"
        )
    return f"exec {quoted} app-server proxy"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("alias")
    parser.add_argument(
        "--codex-path",
        required=True,
        help="Absolute or $HOME-relative path to the remote Codex executable.",
    )
    parser.add_argument("--skip-daemon-start", action="store_true")
    parser.add_argument(
        "--observe-seconds",
        type=float,
        default=0,
        help="Observe notifications after all threads are unsubscribed.",
    )
    args = parser.parse_args()

    if not ALIAS_RE.fullmatch(args.alias):
        raise SpikeError("invalid SSH config alias")
    if "\x00" in args.codex_path or "\n" in args.codex_path:
        raise SpikeError("invalid Codex path")

    command_path = args.codex_path
    if command_path.startswith("$HOME/"):
        command_path = '"$HOME/' + command_path[len("$HOME/") :] + '"'
        command = (
            f"{command_path} app-server daemon start 1>&2"
            f" && exec {command_path} app-server proxy"
            if not args.skip_daemon_start
            else f"exec {command_path} app-server proxy"
        )
    else:
        command = remote_command(command_path, not args.skip_daemon_start)

    ssh_args = [
        "/usr/bin/ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "RemoteCommand=none",
        "-o",
        "PermitLocalCommand=no",
        "--",
        args.alias,
        command,
    ]

    process = subprocess.Popen(
        ssh_args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None

    try:
        request_key = base64.b64encode(os.urandom(16)).decode("ascii")
        expected_accept = base64.b64encode(
            hashlib.sha1(
                (request_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode(
                    "ascii"
                )
            ).digest()
        ).decode("ascii")
        upgrade = (
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: websocket\r\n"
            f"Sec-WebSocket-Key: {request_key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        process.stdin.write(upgrade)
        process.stdin.flush()
        response_headers = read_http_headers(process.stdout).decode(
            "iso-8859-1", errors="replace"
        )
        status_line = response_headers.splitlines()[0]
        if " 101 " not in status_line:
            raise SpikeError(f"WebSocket upgrade failed: {status_line}")
        normalized = response_headers.lower()
        if f"sec-websocket-accept: {expected_accept.lower()}" not in normalized:
            raise SpikeError("WebSocket Sec-WebSocket-Accept did not match")

        initialize, seen = request(
            process.stdin,
            process.stdout,
            1,
            "initialize",
            {
                "clientInfo": {
                    "name": "vibe_status_spike",
                    "title": "Vibe Status protocol spike",
                    "version": "0.1.0",
                }
            },
        )
        send_json(process.stdin, {"method": "initialized", "params": {}})
        loaded, notifications = request(
            process.stdin, process.stdout, 2, "thread/loaded/list", {}
        )
        seen.extend(notifications)
        data = loaded.get("result", {}).get("data", [])
        if not isinstance(data, list):
            raise SpikeError("thread/loaded/list returned an unexpected shape")

        roots = 0
        children = 0
        statuses: dict[str, int] = {}
        next_id = 3
        for thread_id in data:
            if not isinstance(thread_id, str):
                continue
            read_response, notifications = request(
                process.stdin,
                process.stdout,
                next_id,
                "thread/read",
                {"threadId": thread_id, "includeTurns": False},
            )
            next_id += 1
            seen.extend(notifications)
            thread = read_response.get("result", {}).get("thread", {})
            if thread.get("parentThreadId") is None and thread.get(
                "sessionId", thread.get("id")
            ) == thread.get("id"):
                roots += 1
            else:
                children += 1
            status = thread.get("status", {})
            status_type = status.get("type", "unknown")
            statuses[status_type] = statuses.get(status_type, 0) + 1
            _, notifications = request(
                process.stdin,
                process.stdout,
                next_id,
                "thread/unsubscribe",
                {"threadId": thread_id},
            )
            next_id += 1
            seen.extend(notifications)

        server_requests = 0
        status_notifications_after_unsubscribe = 0
        deadline = time.monotonic() + max(0, args.observe_seconds)
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            readable, _, _ = select.select(
                [process.stdout], [], [], min(remaining, 1.0)
            )
            if not readable:
                continue
            message = receive_message(process.stdin, process.stdout)
            incoming_method = message.get("method")
            if isinstance(incoming_method, str):
                seen.append(incoming_method)
                if incoming_method == "thread/status/changed":
                    status_notifications_after_unsubscribe += 1
                if "id" in message:
                    server_requests += 1
                    raise SpikeError(
                        f"server request {incoming_method!r} was received; refusing to answer"
                    )

        print(
            json.dumps(
                {
                    "alias": args.alias,
                    "upgrade": status_line,
                    "initializeResultKeys": sorted(
                        initialize.get("result", {}).keys()
                    ),
                    "loadedThreads": len(data),
                    "rootThreads": roots,
                    "childThreads": children,
                    "statuses": statuses,
                    "notificationsSeen": sorted(set(seen)),
                    "statusNotificationsAfterUnsubscribe":
                        status_notifications_after_unsubscribe,
                    "serverRequestsAnswered": 0,
                    "serverRequestsObserved": server_requests,
                },
                indent=2,
                sort_keys=True,
            )
        )
        send_frame(process.stdin, 0x8, b"")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        stderr = process.stderr.read().decode("utf-8", errors="replace")
        if stderr:
            print(stderr[-4096:], file=sys.stderr, end="")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SpikeError as error:
        print(f"protocol spike failed: {error}", file=sys.stderr)
        raise SystemExit(1)
