#!/usr/bin/python3
"""Bridge a WebSocket byte stream to the local OpenSSH listener."""

import argparse
import base64
import hashlib
import socket
import socketserver
import struct
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 1024 * 1024


def read_exact(sock, length):
    chunks = bytearray()
    while len(chunks) < length:
        data = sock.recv(length - len(chunks))
        if not data:
            raise ConnectionError("peer closed connection")
        chunks.extend(data)
    return bytes(chunks)


def websocket_handshake(client):
    request = bytearray()
    while not request.endswith(b"\r\n\r\n"):
        part = client.recv(1)
        if not part:
            raise ConnectionError("client closed before WebSocket handshake")
        request.extend(part)
        if len(request) > 8192:
            raise ValueError("WebSocket request headers are too large")

    lines = request.decode("latin-1").split("\r\n")
    if not lines or not lines[0].startswith("GET "):
        raise ValueError("WebSocket upgrade requires GET")
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()

    connection_tokens = {token.strip().lower() for token in headers.get("connection", "").split(",")}
    if headers.get("upgrade", "").lower() != "websocket" or "upgrade" not in connection_tokens:
        raise ValueError("request is not a WebSocket upgrade")
    key = headers.get("sec-websocket-key", "")
    if key:
        if headers.get("sec-websocket-version") != "13":
            raise ValueError("unsupported WebSocket version")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        )
    else:
        # HTTP Custom tunnel payloads commonly request the HTTP Upgrade but
        # then carry a raw SSH byte stream without RFC 6455 framing headers.
        response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    client.sendall(response.encode("ascii"))
    return bool(key)


def send_frame(client, payload, opcode=2, lock=None):
    length = len(payload)
    if length < 126:
        header = bytes((0x80 | opcode, length))
    elif length < 65536:
        header = bytes((0x80 | opcode, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x80 | opcode, 127)) + struct.pack("!Q", length)
    if lock:
        with lock:
            client.sendall(header + payload)
    else:
        client.sendall(header + payload)


def websocket_to_ssh(client, upstream, write_lock):
    while True:
        first, second = read_exact(client, 2)
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        if first & 0x70:
            raise ValueError("WebSocket extensions are not supported")
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(client, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(client, 8))[0]
        if not masked or length > MAX_FRAME:
            raise ValueError("invalid or oversized WebSocket frame")
        mask = read_exact(client, 4)
        payload = bytearray(read_exact(client, length))
        for index in range(length):
            payload[index] ^= mask[index % 4]

        if opcode == 0x8:
            send_frame(client, bytes(payload[:125]), opcode=0x8, lock=write_lock)
            return
        if opcode == 0x9:
            send_frame(client, bytes(payload), opcode=0xA, lock=write_lock)
            continue
        if opcode == 0xA:
            continue
        if opcode not in (0x0, 0x1, 0x2):
            raise ValueError("unsupported WebSocket opcode")
        if payload:
            upstream.sendall(payload)
        if not fin and opcode in (0x1, 0x2):
            # Continuation frames carry more bytes in the same TCP stream.
            continue


def raw_tunnel_to_ssh(client, upstream):
    while True:
        data = client.recv(65536)
        if not data:
            return
        upstream.sendall(data)


class BridgeHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        upstream = None
        write_lock = threading.Lock()
        try:
            framed_websocket = websocket_handshake(client)
            upstream = socket.create_connection((self.server.target_host, self.server.target_port), timeout=10)
            upstream.settimeout(None)

            def ssh_to_websocket():
                try:
                    while True:
                        data = upstream.recv(65536)
                        if not data:
                            break
                        if framed_websocket:
                            send_frame(client, data, lock=write_lock)
                        else:
                            client.sendall(data)
                except OSError:
                    pass
                finally:
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

            reader = threading.Thread(target=ssh_to_websocket, daemon=True)
            reader.start()
            if framed_websocket:
                websocket_to_ssh(client, upstream, write_lock)
            else:
                raw_tunnel_to_ssh(client, upstream)
        except (ConnectionError, OSError, ValueError):
            # Closing the socket is enough; Nginx and clients report the failed
            # upgrade/connection without exposing backend details.
            pass
        finally:
            for sock in (upstream, client):
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass


class BridgeServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--target", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=22)
    args = parser.parse_args()
    server = BridgeServer((args.listen, args.port), BridgeHandler)
    server.target_host = args.target
    server.target_port = args.target_port
    server.serve_forever()


if __name__ == "__main__":
    main()
