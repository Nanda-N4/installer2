#!/usr/bin/env python3
from __future__ import annotations
N4_VERSION = '2026.09.24-r10'

import asyncio
import logging
import resource
import signal
from pathlib import Path

CONF = Path('/etc/n4vpn/n4.conf')
LOG = '/var/log/n4vpn/ws-proxy.log'


def cfg() -> dict[str, str]:
    d: dict[str, str] = {}
    if CONF.exists():
        for line in CONF.read_text(errors='ignore').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    return d


def ports(value: str, default: list[int]) -> list[int]:
    out: list[int] = []
    for item in value.split(','):
        try:
            p = int(item.strip())
        except ValueError:
            continue
        if 1 <= p <= 65535 and p not in out:
            out.append(p)
    return out or default


C = cfg()
WS_PORTS = ports(C.get('WS_PORTS', '80,143,442,8080'), [80, 143, 442, 8080])
VPN_SSH_PORT = int(C.get('VPN_SSH_PORT', '109'))
HYBRID_PORT = int(C.get('HYBRID_PORT', '443'))
DROPBEAR_INTERNAL_PORT = int(C.get('DROPBEAR_INTERNAL_PORT', '1443'))
MAX_CLIENTS = max(64, int(C.get('WS_MAX_CLIENTS', '2048')))
IDLE_TIMEOUT = max(30, int(C.get('WS_IDLE_TIMEOUT', '180')))
CLASSIFY_TIMEOUT = 0.40

LISTEN_PORTS = list(dict.fromkeys(WS_PORTS + [HYBRID_PORT]))
HTTP_METHODS = (b'GET ', b'POST ', b'PUT ', b'CONNECT ', b'HEAD ', b'OPTIONS ', b'PATCH ', b'DELETE ')

Path(LOG).parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    handlers=[logging.FileHandler(LOG), logging.StreamHandler()],
)
log = logging.getLogger('n4ws')
sem = asyncio.Semaphore(MAX_CLIENTS)
active = 0


async def close_writer(writer: asyncio.StreamWriter | None) -> None:
    if not writer:
        return
    try:
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while True:
        data = await asyncio.wait_for(reader.read(65536), timeout=IDLE_TIMEOUT)
        if not data:
            return
        writer.write(data)
        await writer.drain()


def looks_http(data: bytes) -> bool:
    head = data[:8192]
    up = head.upper()
    return (
        head.startswith(HTTP_METHODS)
        or b' HTTP/1.' in up
        or b'HOST:' in up
        or b'UPGRADE: WEBSOCKET' in up
    )


def is_websocket_upgrade(data: bytes) -> bool:
    up = data[:8192].upper()
    return b'UPGRADE: WEBSOCKET' in up or b'CONNECTION: UPGRADE' in up


async def bridge(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    backend_reader: asyncio.StreamReader,
    backend_writer: asyncio.StreamWriter,
) -> None:
    tasks = {
        asyncio.create_task(pump(client_reader, backend_writer)),
        asyncio.create_task(pump(backend_reader, client_writer)),
    }
    done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)
    for task in done:
        try:
            task.result()
        except Exception:
            pass


async def http_payload_mode(
    first: bytes,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    """Terminate the HTTP/payload preface then tunnel raw SSH to VPN SSH backend."""
    backend_reader = backend_writer = None
    try:
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection('127.0.0.1', VPN_SSH_PORT), timeout=8
        )

        if is_websocket_upgrade(first):
            writer.write(
                b'HTTP/1.1 101 Switching Protocols\r\n'
                b'Connection: Upgrade\r\n'
                b'Upgrade: websocket\r\n\r\n'
            )
        else:
            writer.write(
                b'HTTP/1.1 200 Connection Established\r\n'
                b'Connection: keep-alive\r\n\r\n'
            )
        await writer.drain()

        await bridge(reader, writer, backend_reader, backend_writer)
    finally:
        await close_writer(backend_writer)


async def raw_dropbear_mode(
    first: bytes,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    backend_reader = backend_writer = None
    try:
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection('127.0.0.1', DROPBEAR_INTERNAL_PORT), timeout=8
        )
        if first:
            backend_writer.write(first)
            await backend_writer.drain()
        await bridge(reader, writer, backend_reader, backend_writer)
    finally:
        await close_writer(backend_writer)


async def normal_ws_mode(
    first: bytes,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:

    if looks_http(first):
        await http_payload_mode(first, reader, writer)
        return

    backend_reader = backend_writer = None
    try:
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection('127.0.0.1', VPN_SSH_PORT), timeout=8
        )
        backend_writer.write(first)
        await backend_writer.drain()
        await bridge(reader, writer, backend_reader, backend_writer)
    finally:
        await close_writer(backend_writer)


async def client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    global active
    try:
        await asyncio.wait_for(sem.acquire(), timeout=0.10)
    except asyncio.TimeoutError:
        await close_writer(writer)
        return

    active += 1
    try:
        local = writer.get_extra_info('sockname')
        local_port = local[1] if local else 0

        if local_port == HYBRID_PORT:
            try:
                first = await asyncio.wait_for(reader.read(65536), timeout=CLASSIFY_TIMEOUT)
            except asyncio.TimeoutError:
                first = b''

            if first and looks_http(first):
                await http_payload_mode(first, reader, writer)
            else:
                await raw_dropbear_mode(first, reader, writer)
            return

        first = await asyncio.wait_for(reader.read(65536), timeout=10)
        if not first:
            return
        await normal_ws_mode(first, reader, writer)

    except (asyncio.TimeoutError, ConnectionError, OSError):
        pass
    except Exception:
        log.exception('proxy error')
    finally:
        active -= 1
        sem.release()
        await close_writer(writer)


async def stats() -> None:
    while True:
        await asyncio.sleep(60)
        log.info(
            'active=%d/%d vpn_backend=127.0.0.1:%d hybrid=:%d dropbear_backend=127.0.0.1:%d',
            active,
            MAX_CLIENTS,
            VPN_SSH_PORT,
            HYBRID_PORT,
            DROPBEAR_INTERNAL_PORT,
        )


async def main() -> None:
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, 262144), hard), hard))
    except Exception:
        pass

    servers = []
    for port in LISTEN_PORTS:
        server = await asyncio.start_server(
            client,
            '0.0.0.0',
            port,
            backlog=4096,
            reuse_address=True,
        )
        servers.append(server)
        if port == HYBRID_PORT:
            log.info(
                'listen :%d HYBRID -> raw SSH dropbear :%d / HTTP payload VPN SSH :%d',
                port,
                DROPBEAR_INTERNAL_PORT,
                VPN_SSH_PORT,
            )
        else:
            log.info('listen :%d payload/ws -> VPN SSH :%d', port, VPN_SSH_PORT)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass

    stat_task = asyncio.create_task(stats())
    await stop.wait()
    stat_task.cancel()
    await asyncio.gather(stat_task, return_exceptions=True)
    for server in servers:
        server.close()
    await asyncio.gather(*(server.wait_closed() for server in servers))


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
