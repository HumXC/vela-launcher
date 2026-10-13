#!/usr/bin/env python3
"""Supervise genuine production loader acceptance without touching the user's data.

Build: nix develop --command zig build build-loader-acceptance
Example: python3 scripts/loader_acceptance.py --loader fabric --base 1.21.8
  --version 0.17.3 --java /absolute/jdk21/bin/java --mode launch
  --cage /absolute/cage --grim /absolute/grim --seconds 90
Reuse the printed --session to perform install, dryrun and launch on one instance.
No fake downloads, Java substitution, authentication, or global configuration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

SENSITIVE = ('token', 'password', 'secret', 'credential', 'clientid', 'xuid',
             'userproperties', 'session', 'authorization')

def acceptance_failed(returncode, failure, forced, report):
    return bool(returncode != 0 or failure or forced or report.get('failure') or
                report['live_residual_pids'] or report.get('supervisor_failure') or
                report.get('artifact_verification_failure') or
                report['binary_replaced_during_run'] or
                (report.get('published') and not all(report.get(key) for key in
                 ('receipt_hash_verified', 'client_hash_verified', 'metadata_hash_verified'))))


def sanitize(argv):
    result, secret = [], False
    for arg in argv:
        key = arg.split('=', 1)[0].lower().lstrip('-')
        sensitive = any(word in key for word in SENSITIVE)
        if secret:
            result.append('<redacted>')
        elif sensitive and '=' in arg:
            result.append(arg.split('=', 1)[0] + '=<redacted>')
        else:
            result.append(arg)
        secret = not secret and sensitive and '=' not in arg
    return result


def process_rows(session_id):
    """Read only the session created by our own start_new_session child."""
    rows = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            values = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            if int(values[3]) != session_id:
                continue
            argv = [part.decode('utf-8', errors='replace') for part in
                    (entry / 'cmdline').read_bytes().split(b'\0') if part]
            rows.append({'pid': int(entry.name), 'pgid': int(values[2]),
                         'state': values[0], 'argv': argv})
        except (OSError, ValueError, IndexError):
            pass
    return rows


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def isolated_environment(session):
    allowed = ('PATH', 'ALSOFT_DRIVERS', 'LD_LIBRARY_PATH', 'LIBRARY_PATH', 'SSL_CERT_FILE',
               'SSL_CERT_DIR', 'NIX_SSL_CERT_FILE', 'LOCALE_ARCHIVE', 'LANG',
               'LC_ALL', 'XKB_CONFIG_ROOT', '__EGL_VENDOR_LIBRARY_FILENAMES',
               'LIBGL_DRIVERS_PATH', 'VK_ICD_FILENAMES')
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    mapping = {'HOME': 'home', 'XDG_RUNTIME_DIR': 'runtime',
               'XDG_CONFIG_HOME': 'config', 'XDG_DATA_HOME': 'data',
               'XDG_CACHE_HOME': 'cache', 'XDG_STATE_HOME': 'state', 'TMPDIR': 'tmp'}
    for key, name in mapping.items():
        path = session / name
        path.mkdir(mode=0o700, exist_ok=True)
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            raise ValueError('Unsafe isolation directory: ' + name)
        path.chmod(0o700)
        env[key] = str(path)
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
               WLR_RENDERER='gles2', LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_DIRS=str(session / 'config'),
               XDG_DATA_DIRS=str(session / 'data'))
    return env


def capture_grim(grim, env, session, destination):
    sockets = [p for p in (session / 'runtime').glob('wayland-*')
               if stat.S_ISSOCK(p.stat().st_mode)]
    if len(sockets) != 1:
        return {'failure': 'IsolatedWaylandSocketNotUnique'}
    bound = dict(env, WAYLAND_DISPLAY=sockets[0].name)
    result = subprocess.run([grim, str(destination)], env=bound,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=15)
    return {'path': str(destination), 'wayland_display': sockets[0].name,
            'returncode': result.returncode,
            'sha256': sha256(destination) if result.returncode == 0 else None,
            'inspection': 'pending: read the PNG before accepting graphical startup'}


def finalize_artifacts(report, session):
    receipt_path = report.get('receipt_path')
    if not receipt_path:
        return
    path = Path(receipt_path)
    root = (session / 'launcher' / '.minecraft').resolve()
    if not path.resolve().is_relative_to(root) or path.is_symlink():
        raise ValueError('ReceiptOutsideIsolatedRoot')
    receipt = read_json(path)
    report['artifact_receipt'] = receipt
    report['receipt_hash_verified'] = sha256(path) == report.get('receipt_sha256')
    # Hash real installed files, including processor outputs, without trusting names.
    artifacts = []
    for file in sorted(root.rglob('*')):
        if file.suffix not in ('.jar', '.json') or not file.is_file():
            continue
        if file.is_symlink() or not file.resolve().is_relative_to(root):
            raise ValueError('ArtifactOutsideIsolatedRoot')
        artifacts.append({'path': str(file.relative_to(root)),
                          'size': file.stat().st_size, 'sha256': sha256(file)})
    report['artifacts'] = artifacts
    client = root / 'versions' / 'Acceptance' / 'Acceptance.jar'
    report['client_hash_verified'] = (client.is_file() and
                                     sha256(client) == receipt.get('client_sha256'))
    document = root / 'versions' / 'Acceptance' / 'Acceptance.json'
    report['metadata_hash_verified'] = (document.is_file() and
        sha256(document) == receipt.get('metadata_sha256') == report.get('metadata_sha256'))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', default='zig-out/bin/vela-loader-acceptance')
    parser.add_argument('--session', help='Reuse only a marked, private /tmp session')
    parser.add_argument('--loader', choices=['vanilla', 'fabric', 'quilt', 'forge', 'neoforge'], required=True)
    parser.add_argument('--base', required=True)
    parser.add_argument('--version')
    parser.add_argument('--java', help='Exact absolute native Java executable')
    parser.add_argument('--installer-java', help='Separate exact processor Java executable')
    parser.add_argument('--mode', choices=['catalogue', 'install', 'dryrun', 'launch'], default='dryrun')
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--memory', type=int, default=2048)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--cancel-after-ms', type=int)
    parser.add_argument('--jvm-arg', action='append', default=[])
    parser.add_argument('--game-arg', action='append', default=[])
    parser.add_argument('--cage', help='Exact pinned Cage executable for isolated graphical startup')
    parser.add_argument('--grim', help='Exact pinned Grim executable; requires Cage')
    parser.add_argument('--x11', action='store_true',
                        help='Run the managed client through Cage XWayland for older Minecraft/GLFW')
    parser.add_argument('--screenshot-after', type=int, default=20)
    args = parser.parse_args()
    if args.mode != 'catalogue':
        if not args.java or not Path(args.java).is_absolute():
            parser.error('--java must be an absolute executable path')
        if args.loader != 'vanilla' and not args.version:
            parser.error('--version must identify the exact loader release')
    if args.installer_java and not Path(args.installer_java).is_absolute():
        parser.error('--installer-java must be an absolute executable path')
    if args.cage and args.mode != 'launch' or args.grim and not args.cage:
        parser.error('Cage requires launch mode; Grim requires Cage')
    # Extra launch arguments must never substitute online identity or contain credentials.
    if any(any(word in arg.lower() for word in SENSITIVE)
           for arg in args.jvm_arg + args.game_arg):
        parser.error('Credential or identity overrides are forbidden in acceptance arguments')
    session = (Path(args.session).absolute() if args.session else
               Path(tempfile.mkdtemp(prefix='vela-loader-acceptance-', dir='/tmp')))
    if (not session.resolve().is_relative_to(Path('/tmp')) or session == Path('/tmp')
            or session.is_symlink() or session.stat().st_uid != os.getuid()
            or stat.S_IMODE(session.stat().st_mode) != 0o700):
        parser.error('Session must be a private directory inside /tmp')
    marker = session / '.vela-loader-acceptance'
    if args.session and not marker.is_file():
        parser.error('Refusing reuse of an unmarked directory')
    marker.touch(mode=0o600)
    env = isolated_environment(session)
    root = session / 'launcher'
    root.mkdir(mode=0o700, exist_ok=True)
    if root.is_symlink():
        parser.error('Launcher root cannot be a symlink')
    run = session / ('run-' + str(time.time_ns()))
    run.mkdir(mode=0o700)
    native_report, report_path, cancel = run / 'native-report.json', run / 'report.json', run / 'cancel'
    binary_path = Path(args.binary).resolve()
    binary_sha256 = sha256(binary_path)
    command = [str(binary_path), '--root', str(root), '--report', str(native_report),
               '--cancel-file', str(cancel), '--loader', args.loader, '--base', args.base,
               '--mode', args.mode, '--seconds', str(args.seconds), '--memory', str(args.memory)]
    for key, value in (('version', args.version), ('java', args.java),
                       ('installer-java', args.installer_java)):
        if value is not None:
            command.extend(['--' + key, value])
    for key, values in (('jvm-arg', args.jvm_arg), ('game-arg', args.game_arg)):
        for value in values:
            command.extend(['--' + key, value])
    if args.x11:
        if not args.cage:
            parser.error('--x11 requires the isolated Cage compositor')
        # Cage keeps its private Wayland socket for screenshots. Only its client
        # loses Wayland discovery, so the official GLFW library uses Cage DISPLAY.
        command = [sys.executable, '-c',
                   'import os, sys; env = dict(os.environ); '
                   'env.pop("WAYLAND_DISPLAY", None); env.pop("WAYLAND_SOCKET", None); '
                   'env["XDG_SESSION_TYPE"] = "x11"; '
                   'os.execve(sys.argv[1], sys.argv[1:], env)'] + command
    if args.cage:
        command = [args.cage, '-D', '-d', '--'] + command
    interrupted = False
    def request_cancel(_signal, _frame):
        nonlocal interrupted
        interrupted = True
        cancel.touch(mode=0o600)
    signal.signal(signal.SIGINT, request_cancel)
    signal.signal(signal.SIGTERM, request_cancel)
    observations, screenshots, forced, failure = [], [], False, None
    seen = set()
    start, running_at, cancel_at = time.monotonic(), None, None
    with (run / 'supervisor.log').open('wb') as log:
        child = subprocess.Popen(command, env=env, cwd=session, stdout=log,
                                 stderr=log, start_new_session=True)
        pgid = child.pid
        write_json(run / 'ownership.json', {'pid': child.pid, 'pgid': pgid,
                                           'session': str(session), 'runtime': env['XDG_RUNTIME_DIR']})
        try:
            while child.poll() is None:
                now = time.monotonic()
                if (now - start > args.timeout or interrupted or
                    args.cancel_after_ms is not None and (now - start) * 1000 >= args.cancel_after_ms):
                    cancel.touch(mode=0o600)
                    cancel_at = cancel_at or now
                for row in process_rows(pgid):
                    argv = row.pop('argv')
                    if not argv or argv[0] not in (args.java, args.installer_java):
                        continue
                    # Exclude bounded -version probes; retain actual processors and game.
                    if '-version' in argv:
                        continue
                    key = (row['pid'], tuple(argv))
                    if key in seen:
                        continue
                    seen.add(key)
                    row.update(argv_sanitized=sanitize(argv),
                               role='game' if '--gameDir' in argv else 'installer',
                               observed_seconds=round(now - start, 3))
                    observations.append(row)
                current = read_json(native_report)
                if current.get('native_java_started'):
                    running_at = running_at or now
                if args.grim and not screenshots and running_at and now - running_at >= args.screenshot_after:
                    screenshots.append(capture_grim(args.grim, env, session, run / 'startup.png'))
                if cancel_at and now - cancel_at > 60:
                    forced = True
                    break
                time.sleep(0.1)
        except Exception as err:
            failure = type(err).__name__ + ': ' + str(err)
            cancel.touch(mode=0o600)
            try:
                child.wait(timeout=60)
            except subprocess.TimeoutExpired:
                forced = True
        finally:
            # Only groups from our owned session, never a process-name kill.
            live = [row for row in process_rows(pgid) if row['state'] != 'Z']
            groups = {row['pgid'] for row in live} | ({pgid} if child.poll() is None else set())
            for group in groups:
                if group <= 1 or group == os.getpgrp():
                    raise RuntimeError('UnsafeOwnedProcessGroup')
                try:
                    os.killpg(group, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                forced = True
                os.killpg(pgid, signal.SIGKILL)
                child.wait(timeout=5)
            for row in process_rows(pgid):
                if row['state'] != 'Z':
                    try:
                        os.killpg(row['pgid'], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            deadline = time.monotonic() + 5
            while any(row['state'] != 'Z' for row in process_rows(pgid)) and time.monotonic() < deadline:
                time.sleep(0.1)
    report = read_json(native_report)
    if not report:
        report = {'failure': 'NativeReportMissing', 'genuine': True, 'offline': True}
    report.update(binary_path=str(binary_path), binary_sha256=binary_sha256,
                  binary_replaced_during_run=sha256(binary_path) != binary_sha256,
                  session=str(session), report_path=str(report_path), process_group=pgid,
                  supervisor_returncode=child.returncode, forced_cleanup=forced,
                  live_residual_pids=[row['pid'] for row in process_rows(pgid) if row['state'] != 'Z'],
                  observed_java_processes=observations, screenshots=screenshots,
                  supervisor_failure=failure)
    report['actual_argv_sanitized'] = next((row['argv_sanitized'] for row in observations
                                          if row['role'] == 'game'), None)
    try:
        finalize_artifacts(report, session)
    except (OSError, ValueError) as err:
        report['artifact_verification_failure'] = type(err).__name__ + ': ' + str(err)
    if args.mode == 'launch' and report.get('native_java_started') and report['actual_argv_sanitized'] is None:
        report['supervisor_failure'] = 'ActualNativeJavaArgvNotObserved'
    write_json(report_path, report)
    print(json.dumps({'session': str(session), 'report': str(report_path),
                      'phase': report.get('phase'), 'failure': report.get('failure'),
                      'processes_joined': not report['live_residual_pids']}))
    return 1 if acceptance_failed(child.returncode, failure, forced, report) else 0


if __name__ == '__main__':
    raise SystemExit(main())
