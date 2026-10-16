"""Offline-only release tests: synthetic memory data and a 127.0.0.1 RTU simulator.
No physical device address is accepted by the simulator. Requires Python 3 and
Windows PowerShell 5.1 or PowerShell 7. Run: python tests/test_monitor.py --shell powershell
"""
import argparse
import csv
import json
import pathlib
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'BYD-HVM-Live-v1.5-EN.ps1'


def crc(data):
    value = 0xffff
    for b in data:
        value ^= b
        for _ in range(8):
            value = (value >> 1) ^ (0xa001 if value & 1 else 0)
    return value


def frame(data):
    return data + struct.pack('<H', crc(data))


def exact(conn, n):
    result = bytearray()
    while len(result) < n:
        b = conn.recv(n - len(result))
        if not b:
            raise EOFError()
        result.extend(b)
    return bytes(result)


def tower_words(tower):
    words = [0] * 256
    words[0:2] = [3370, 3350]
    words[3:5] = [26, 20]
    words[6] = 0x8001
    words[7] = 1
    words[12] = 0x8000
    words[13] = 0xffff  # unused 8th-module slots MUST be excluded
    words[14:18] = [65535, 0x8000, 0x3456, 0x12]
    words[18] = 0xab34
    words[20] = 3752
    words[23] = 3753
    words[24] = 950 + tower
    words[25] = 95 + tower
    words[26] = 65536 - 10 * tower
    words[27] = 5
    serial = ('TEST-CONTROLLER-%03d' % tower).encode().ljust(24, b'\x00')
    for i in range(12):
        words[33+i] = int.from_bytes(serial[2*i:2*i+2], 'big')
    words[48:160] = [3350] * 112
    words[157] = 3370
    return words


class Simulator:
    def __init__(self, failure=None):
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0))
        self.server.listen(4)
        self.server.settimeout(0.2)
        self.port = self.server.getsockname()[1]
        self.stop = threading.Event()
        self.failure = failure
        self.injected = False
        self.error = None
        self.requests = []
        self.connects = 0
        self.disconnect_at = None
        self.reconnect_delay = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connects += 1
            if self.disconnect_at is not None and self.reconnect_delay is None:
                self.reconnect_delay = time.monotonic() - self.disconnect_at
            try:
                with conn:
                    conn.settimeout(20)
                    self.handle(conn)
            except (EOFError, ConnectionResetError, BrokenPipeError, socket.timeout):
                self.disconnect_at = time.monotonic()
            except Exception as exc:
                self.error = repr(exc)
                self.stop.set()

    def handle(self, conn):
        selected = 0
        chunk = 0
        busy = False
        configured = False
        while not self.stop.is_set():
            header = exact(conn, 6)
            unit, fn, addr, count = struct.unpack('>BBHH', header)
            assert unit == 1
            if fn == 3:
                request = header + exact(conn, 2)
            elif fn == 16:
                n = exact(conn, 1)
                request = header + n + exact(conn, n[0] + 2)
            else:
                raise AssertionError('Unexpected function: %s' % fn)
            assert crc(request[:-2]) == int.from_bytes(request[-2:], 'little')
            self.requests.append((fn, addr, count))
            if fn == 16:
                assert configured, 'A reconnect must validate configuration before selection'
                assert (addr, count) == (0x550, 2)
                assert request[6:8] == b'\x04\x00'
                selected = request[8]
                assert 1 <= selected <= 3 and request[9:11] == b'\x81\x00'
                chunk = 0
                busy = self.failure == 'ready' and selected == 2 and not self.injected
                if busy:
                    self.injected = True
                answer = frame(header)
            else:
                assert (addr, count) in [(0, 102), (0x500, 25), (0x551, 1), (0x558, 65)]
                if addr == 0:
                    words = [0]*102
                    words[0:12] = [0x5445]*12
                    words[16] = 0x37
                    words[17] = 0x0102
                    configured = True
                elif addr == 0x500:
                    words = [0]*25
                    words[0] = 96
                    words[1:4] = [337, 335, 98]
                    words[4] = 65476  # -6.0 A
                    words[5] = 37520
                    words[6:8] = [26, 20]
                    words[17:21] = [65535, 0xffff, 1, 0]
                elif addr == 0x551:
                    words = [0x8100 if busy else 0x8801]
                else:
                    assert selected and chunk < 4 and not busy
                    words = [128] + tower_words(selected)[64*chunk:64*(chunk+1)]
                    chunk += 1
                answer = frame(bytes([1, 3, 2*len(words)]) + struct.pack('>'+'H'*len(words), *words))
                if self.failure == 'crc' and selected == 2 and addr == 0x558 and not self.injected:
                    self.injected = True
                    answer = answer[:-1] + bytes([answer[-1] ^ 1])
            # TCP fragmentation is intentional, not one-frame-per-recv.
            conn.sendall(answer[:2])
            time.sleep(0.003)
            conn.sendall(answer[2:7])
            if len(answer) > 7:
                conn.sendall(answer[7:])

    def close(self):
        self.stop.set()
        self.server.close()
        self.thread.join(timeout=1)
        assert self.error is None, self.error


def run(shell, args, timeout=100):
    cmd = [shell, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(SCRIPT)] + args
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if p.returncode:
        raise AssertionError('Command failed %r\n%s\n%s' % (args, p.stdout, p.stderr))
    return p.stdout


def rows(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f, delimiter=';'))


def check_logs(root, simulation=False):
    directories = list(pathlib.Path(root).iterdir())
    assert len(directories) == 1
    folder = directories[0]
    cells = rows(folder/'cells.csv')
    assert cells, 'No completed tower samples'
    assert {x['LogicalTower'] for x in cells} == {'1', '2', '3'}
    for row in cells:
        assert None not in row, 'CSV field count mismatch'
        assert all(v is not None for v in row.values()), 'CSV missing values'
        flags = [int(row['M%02d_C%02d_BalanceFlag' % (m, c)]) for m in range(1,8) for c in range(1,17)]
        assert sum(flags) == int(row['BalanceFlagCount'])
        if not simulation:
            assert flags[0] == flags[15] == flags[16] == flags[111] == 1
            assert sum(flags) == 4
            assert int(row['ChargeEnergyCounter_Wh']) == 0x8000ffff
            assert int(row['SOC_Calibration_Raw_HighByte_Word18']) == 171
            assert int(row['SOH_reported_pct']) == 95 + int(row['LogicalTower'])
    modules = rows(folder/'modules.csv')
    assert len(modules) == 7*len(cells)
    for row in modules:
        assert None not in row and all(v is not None for v in row.values())
    status = rows(folder/'system.csv')
    assert status
    if not simulation:
        assert float(status[-1]['ChargeEnergyCounter_kWh']) == 429496729.5
    snap = json.loads((folder/'snapshot-latest.json').read_text(encoding='utf-8-sig'))
    assert snap['AppVersion'] == '1.5' and snap['SchemaVersion'] == 2
    assert len(snap['Towers']) == 3
    raw = [json.loads(line) for line in (folder/'raw.ndjson').read_text(encoding='utf-8-sig').splitlines()]
    assert raw and all(x['AppVersion'] == '1.5' for x in raw)
    return raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--shell', default='powershell')
    parser.add_argument('--skip-recovery', action='store_true')
    args = parser.parse_args()
    shell = shutil.which(args.shell)
    if not shell:
        raise SystemExit('PowerShell executable not found: '+args.shell)
    assert 'SELFTEST OK' in run(shell, ['-SelfTest'])
    for modules in (3, 8):
        assert 'SELFTEST OK' in run(shell, ['-SelfTest','-ModulesPerTower',str(modules),'-WatchModule',str(modules)])
    assert 'PROTOCOL' in run(shell, ['/?'])
    with tempfile.TemporaryDirectory() as temp:
        run(shell, ['-Demo','-Plain','-MaxScans','2','-ScanSeconds','5','-OutputDirectory',temp])
        check_logs(temp, simulation=True)
    for failure in ([None] if args.skip_recovery else [None,'ready','crc']):
        sim = Simulator(failure)
        try:
            with tempfile.TemporaryDirectory() as temp:
                args_monitor = ['/127.0.0.1','-Port',str(sim.port),'-Plain','-ScanSeconds','5','-MaxScans',('2' if failure is None else '10'),'-OutputDirectory',temp]
                output = run(shell, args_monitor)
                raw = check_logs(temp)
                if failure:
                    assert sim.injected and sim.connects >= 2
                    assert sim.reconnect_delay is not None and sim.reconnect_delay >= 19
                    assert any(x['Type']=='CommunicationError' for x in raw), [x['Type'] for x in raw]
                print('PASS: loopback scenario %s, %s requests, %s TCP connections' % (failure or 'normal', len(sim.requests), sim.connects))
        finally:
            sim.close()
    print('PASS: self-test, help, demo, CSV schema, masks, unsigned energy and RTU transport/recovery')


if __name__ == '__main__':
    main()
