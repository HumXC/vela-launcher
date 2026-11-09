#!/usr/bin/env python3
"""Linux SAME-App controlled-process acceptance. Never builds or uses real auth/CF.

Pinned Python commands:
  lifecycle_acceptance.py freeze --pins CALLER.json --output FREEZE.json
  lifecycle_acceptance.py run --freeze FREEZE.json --case CASE --root FRESH_ABSOLUTE

Caller keys: workspace, app, helper, python, lowlevel, font, ca, tools
{cage,wayvnc,vncdotool,grim}, package_roots, python_roots, libraries.
File pins are {path,sha256}; roots are absolute canonical directories. Package
roots cover installed zig-pkg; Python roots cover interpreter + standard VNC ABI.
Tool paths are caller-pinned, never ambient lookups or obsolete store fallbacks.
The freeze binds build/import/package/consumer bytes and eight ordered libraries.
Only digest-verified low-level utilities from gui_layout_acceptance.py are reused.

IPC arms a real borrowed-scope world list or starts the production GameController.
Close/dialog input is real compositor input. Every run retains evidence. No
process-name/group kills, fake policy/EndEvent/task counts, Home Start UI claim,
JVM/Minecraft gameplay claim, universal JOIN claim, or real desktop/GPU claim.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import runpy
import select
import signal
import socket
import stat
import subprocess
import sys
import time
import types

CASES = ('restore', 'close_preparing', 'close_running', 'debug', 'abnormal',
         'exit_together', 'idle_keep', 'idle_auxiliary', 'idle_cancel', 'ordinary_destroy')
LIBRARIES = (
 '/nix/store/gvgz0nm1mwj50k0xd2pr78bx9m5mjxvj-alsa-lib-1.2.16.1/lib',
 '/nix/store/c7z4kv21nh2y5mvfyhj1ixkgxwc420z4-libdecor-0.2.5/lib',
 '/nix/store/6lxb0vhv7gxpdcdirbfmm75vi4idjjhq-libusb-1.0.30/lib',
 '/nix/store/yk95z4hjlzdk418px0fc797qszccfj5p-libxkbcommon-1.13.2/lib',
 '/nix/store/lk4614327cn1h9z3m6cvnls95n13m1cj-vulkan-loader-1.4.357.0/lib',
 '/nix/store/vjcwhp0milwa1jqy1inpjxrsh8hjrgwc-wayland-1.26.0/lib',
 '/nix/store/4hlgp6r4j5p6b2b9sxw01cba0x3fjxd6-systemd-minimal-libs-261.2/lib',
 '/nix/store/rarvfpm927fcbd6b9p0crg09w9r3ywb3-libglvnd-1.7.0/lib',
)
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC
LIMIT = 128 * 1024 * 1024


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))


def canonical(path):
    require(isinstance(path, str) and os.path.isabs(path) and os.path.realpath(path) == path,
            'Noncanonical path: ' + str(path))
    return path


def node(s):
    return (s.st_dev, s.st_ino, s.st_uid, stat.S_IFMT(s.st_mode), stat.S_IMODE(s.st_mode))


def stamp(s):
    return [s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def content(path, limit=LIMIT):
    canonical(path)
    before = os.stat(path, follow_symlinks=False)
    require(stat.S_ISREG(before.st_mode) and before.st_size <= limit and not (before.st_mode & 0o022),
            'Unsafe input: ' + path)
    fd = os.open(path, os.O_RDONLY | NOFOLLOW)
    try:
        require(node(os.fstat(fd)) == node(before), 'Input open raced')
        data = bytearray()
        while True:
            chunk = os.read(fd, min(1024 * 1024, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= limit, 'Input too large')
        require(stamp(os.fstat(fd)) == stamp(before) and
                node(os.stat(path, follow_symlinks=False)) == node(before), 'Input bytes raced')
        return bytes(data)
    finally:
        os.close(fd)


def record(path):
    raw = content(canonical(path))
    s = os.stat(path, follow_symlinks=False)
    return {'path': path, 'sha256': hashlib.sha256(raw).hexdigest(), 'node': list(node(s)), 'stamp': stamp(s)}


def verify(row, full=True):
    s = os.stat(row['path'], follow_symlinks=False)
    require(list(node(s)) == row['node'] and stamp(s) == row['stamp'], 'Frozen identity/bytes drift: ' + row['path'])
    if full:
        require(hashlib.sha256(content(row['path'])).hexdigest() == row['sha256'], 'Frozen digest drift')


def pin(row):
    require(set(row) == {'path', 'sha256'}, 'Invalid caller pin')
    actual = record(row['path'])
    require(actual['sha256'] == row['sha256'], 'Caller digest mismatch')
    return actual


def lowlevel(row):
    verify(row)
    module = types.ModuleType('vela_lifecycle_lowlevel')
    module.__file__ = row['path']
    sys.modules[module.__name__] = module
    exec(compile(content(row['path']), row['path'], 'exec'), module.__dict__)
    return module


def inventory(roots):
    files, links = {}, {}
    for root in roots:
        canonical(root)
        require(os.path.isdir(root) and not os.path.islink(root), 'Invalid closure root')
        for directory, dirs, names in os.walk(root, followlinks=False):
            for name in dirs + names:
                path = os.path.join(directory, name)
                if os.path.islink(path):
                    require(name not in dirs, 'Linked closure directory is unsupported')
                    target = canonical(os.path.realpath(path))
                    require(target.startswith('/nix/store/') or any(target.startswith(r + '/') for r in roots),
                            'Closure link leaves pinned roots and immutable store')
                    links[path] = {'path': path, 'target': os.readlink(path),
                                   'node': list(node(os.stat(path, follow_symlinks=False)))}
                    files[target] = record(target)
                elif name in names:
                    files[path] = record(path)
    return [files[p] for p in sorted(files)], [links[p] for p in sorted(links)]


def source_closure(workspace):
    pending = [workspace + '/' + p for p in ('src/lifecycle_acceptance.zig', 'src/lifecycle_acceptance_child.zig',
               'src/core/worlds_gzip.zig', 'build.zig', 'build.zig.zon', 'build-support/macos_sdk.zig')]
    found = {}
    while pending:
        path = pending.pop()
        require(path.startswith(workspace + '/'), 'Import escaped workspace')
        if path in found:
            continue
        found[path] = record(path)
        if path.endswith('.zig'):
            for target in re.findall(r'@(?:import|embedFile)\("([^"\n]+)"\)', content(path).decode()):
                candidate = os.path.normpath(os.path.join(os.path.dirname(path), target))
                if target.endswith('.zig') or os.path.isfile(candidate):
                    pending.append(candidate)
    return [found[p] for p in sorted(found)]


def freeze(args):
    spec = decode(content(canonical(args.pins), 1024 * 1024))
    require(set(spec) == {'workspace', 'app', 'helper', 'python', 'lowlevel', 'font', 'ca',
                         'tools', 'package_roots', 'python_roots', 'libraries'}, 'Invalid caller schema')
    workspace = canonical(spec['workspace'])
    require(workspace == str(Path(__file__).resolve().parent.parent), 'Wrong workspace')
    require(tuple(spec['libraries']) == LIBRARIES, 'Eight ordered library directories required')
    require(set(spec['tools']) == {'cage', 'wayvnc', 'vncdotool', 'grim'}, 'Invalid tool set')
    pins = {key: pin(spec[key]) for key in ('app', 'helper', 'python', 'lowlevel', 'font', 'ca')}
    pins['tools'] = {key: pin(value) for key, value in spec['tools'].items()}
    require(os.path.basename(pins['app']['path']) == 'vela-lifecycle-acceptance' and
            os.path.basename(pins['helper']['path']) == 'vela-lifecycle-child', 'Wrong artifacts')
    require(pins['lowlevel']['path'] == workspace + '/scripts/gui_layout_acceptance.py', 'Wrong low-level consumer')
    require(pins['tools']['grim']['path'] == '/nix/store/x1zb4lfyibpvjzbmij7zn91rvv2fwify-grim-1.5.0/bin/grim', 'Wrong grim')
    h = lowlevel(pins['lowlevel'])
    libraries = []
    for path in LIBRARIES:
        fd, identity = h.pin_library_directory(path)
        os.close(fd)
        libraries.append({'path': path, 'node': identity})
    installed = {str(p.resolve()) for p in Path(workspace, 'zig-pkg').iterdir() if p.is_dir()}
    require(installed == set(spec['package_roots']), 'Incomplete installed package closure')
    require(any(pins['python']['path'].startswith(p + '/') for p in spec['python_roots']), 'Missing interpreter ABI closure')
    packages, package_links = inventory(spec['package_roots'])
    python_files, python_links = inventory(spec['python_roots'])
    result = {'version': 1, 'workspace': workspace, 'pins': pins, 'libraries': libraries,
              'sources': source_closure(workspace), 'packages': packages, 'python_closure': python_files,
              'links': package_links + python_links, 'driver': record(str(Path(__file__).resolve()))}
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(json.dumps(result, indent=2, sort_keys=True).encode() + b'\n')
    print(args.output)


class Frozen:
    def __init__(self, path):
        self.record = record(canonical(path))
        self.path = path
        self.spec = decode(content(path))
        require(self.spec['version'] == 1 and self.spec['driver']['path'] == str(Path(__file__).resolve()), 'Wrong frozen consumer')
        self.h = lowlevel(self.spec['pins']['lowlevel'])
        self.libraries = []
        require(tuple(row['path'] for row in self.spec['libraries']) == LIBRARIES, 'Wrong library order')
        for row in self.spec['libraries']:
            fd, actual = self.h.pin_library_directory(row['path'])
            require(actual == row['node'], 'Library directory drift')
            self.libraries.append((fd, actual, row['path']))
        self.critical_files = [self.record, self.spec['driver']] + self.spec['sources']
        self.files = self.critical_files + self.spec['packages'] + self.spec['python_closure']
        for key, value in self.spec['pins'].items():
            entries = list(value.values()) if key == 'tools' else [value]
            self.files.extend(entries)
            self.critical_files.extend(entries)
        self.guard(full=True)
        require(self.h.identity(os.getpid())['exe'] == self.spec['pins']['python']['path'], 'Wrong executing Python ABI')
        self.abi = {row['path']: row for row in self.spec['python_closure']}

    def guard(self, full=False, probe_critical=False):
        # Full closure checks surround the short, real 2-second Java probe.
        # During it, retain all source/tool and live-process checks.
        for row in (self.critical_files if probe_critical else self.files):
            verify(row, full=full)
        for row in self.spec['links']:
            require(list(node(os.stat(row['path'], follow_symlinks=False))) == row['node'] and
                    os.readlink(row['path']) == row['target'], 'Closure link drift')
        for fd, expected, path in self.libraries:
            require(self.h.library_directory_node(os.fstat(fd)) == expected and
                    self.h.library_directory_node(os.stat(path, follow_symlinks=False)) == expected, 'Library FD/path drift')

    def close(self):
        for fd, _, _ in self.libraries:
            os.close(fd)


class Owned:
    def __init__(self, root):
        canonical(os.path.dirname(root))
        require(os.path.isabs(root) and not os.path.lexists(root), 'Owned root must be fresh absolute/nonexistent')
        os.mkdir(root, 0o700)
        self.root = canonical(root)
        self.fds, self.dirs, self.pins, self.mutable = {}, {}, {}, set()
        self.pin_dir('')

    def path(self, name):
        require(not os.path.isabs(name) and '..' not in name.split('/'), 'Unsafe owned relative path')
        return self.root if not name else self.root + '/' + name

    def pin_dir(self, name):
        s = os.stat(self.path(name), follow_symlinks=False)
        require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o700, 'Foreign owned directory')
        fd = os.open(self.path(name), os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
        require(node(os.fstat(fd)) == node(s), 'Directory raced')
        self.dirs[name] = (fd, node(s))

    def parent_fd(self, name):
        parent, leaf = os.path.split(name)
        self.path(name)
        require(parent in self.dirs and bool(leaf), 'Unpinned parent directory: ' + name)
        fd, expected = self.dirs[parent]
        require(node(os.fstat(fd)) == expected and node(os.stat(self.path(parent), follow_symlinks=False)) == expected,
                'Owned parent directory drift')
        return fd, leaf

    def mkdir(self, name):
        parent, leaf = self.parent_fd(name)
        os.mkdir(leaf, 0o700, dir_fd=parent)
        self.pin_dir(name)

    def create(self, name, data=b'', execute=False, mutable=False):
        require(not (execute and mutable), 'Executable owned file cannot be mutable')
        parent, leaf = self.parent_fd(name)
        fd = os.open(leaf, os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o700 if execute else 0o600, dir_fd=parent)
        self.fds[name], self.pins[name] = fd, node(os.fstat(fd))
        if mutable:
            self.mutable.add(name)
        self.write(name, data)
        if execute:
            parent, leaf = self.parent_fd(name)
            self.check_file(name)
            expected = self.pins[name]
            expected_stamp = stamp(os.fstat(fd))
            reader = os.open(leaf, os.O_RDONLY | NOFOLLOW, dir_fd=parent)
            try:
                opened = os.fstat(reader)
                require(node(opened) == expected and stamp(opened) == expected_stamp and
                        opened.st_size == len(data), 'Executable read-only reopen drift: ' + name)
                require(hashlib.sha256(os.pread(reader, len(data), 0)).digest() == hashlib.sha256(data).digest(),
                        'Executable copy digest drift: ' + name)
                named = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                require(node(os.fstat(reader)) == expected and stamp(os.fstat(reader)) == expected_stamp and
                        node(named) == expected and stamp(named) == expected_stamp,
                        'Executable read-only bytes/path raced: ' + name)
                self.check_file(name)
            except BaseException:
                os.close(reader)
                raise
            writer = fd
            self.fds[name] = reader
            fd = reader
            os.close(writer)
            self.check_file(name)
            require(stamp(os.fstat(fd)) == expected_stamp and
                    stamp(os.stat(leaf, dir_fd=parent, follow_symlinks=False)) == expected_stamp,
                    'Executable bytes drift after writer close: ' + name)
        return fd

    def check_file(self, name):
        require(node(os.fstat(self.fds[name])) == self.pins[name] and
                node(os.stat(self.path(name), follow_symlinks=False)) == self.pins[name], 'Owned file FD/path drift: ' + name)

    def write(self, name, data):
        self.check_file(name)
        position = 0
        while position < len(data):
            count = os.pwrite(self.fds[name], data[position:], position)
            require(count > 0, 'Short owned write')
            position += count
        os.ftruncate(self.fds[name], len(data))

    def read(self, name, limit=LIMIT):
        self.check_file(name)
        size = os.fstat(self.fds[name]).st_size
        require(size <= limit, 'Owned node too large')
        return os.pread(self.fds[name], size, 0)

    def guard(self):
        for name, (fd, expected) in self.dirs.items():
            require(node(os.fstat(fd)) == expected and node(os.stat(self.path(name), follow_symlinks=False)) == expected,
                    'Owned directory FD/path drift')
        for name in self.fds:
            self.check_file(name)
        require(set(os.listdir(self.path('ipc'))) == {'command.json', 'status.json', 'world-release', 'probe-release',
                'game-release', 'probe.json', 'game.json'}, 'Unexpected IPC node')
        for directory, dirs, files in os.walk(self.root, followlinks=False):
            for name in dirs + files:
                s = os.stat(os.path.join(directory, name), follow_symlinks=False)
                require(s.st_uid == os.getuid() and not stat.S_ISLNK(s.st_mode), 'Foreign/link owned node')
                require(stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode) or stat.S_ISSOCK(s.st_mode), 'Unexpected owned node type')

    def close(self):
        for fd in self.fds.values():
            os.close(fd)
        for fd, _ in self.dirs.values():
            os.close(fd)


class Run:
    def __init__(self, frozen, root, case):
        self.frozen, self.h, self.case = frozen, frozen.h, case
        self.tree = Owned(root)
        self.nonce, self.sequence = os.urandom(32).hex(), 0
        self.probe_deadline = None
        self.processes, self.jobs, self.history, self.events = {}, {}, [], []
        self.client = self.api = self.gui = None
        self.socket_pins, self.socket_fds = {}, {}
        self.runtime = self.tree.path('runtime')
        self.fixture()

    def fixture(self):
        t = self.tree
        for name in ('.vela', '.minecraft', 'home', 'xdg', 'runtime', 'evidence', 'ipc', 'assets',
                     'xdg/data', 'xdg/config', 'xdg/cache', 'xdg/state', '.vela/logs', '.vela/cache',
                     '.vela/java', '.minecraft/versions', '.minecraft/assets', '.minecraft/assets/indexes',
                     '.minecraft/assets/objects', '.minecraft/libraries'):
            t.mkdir(name)
        for key, name, execute in (('app', 'assets/vela-lifecycle-acceptance', True), ('helper', 'assets/vela-lifecycle-child', True),
                                   ('font', 'assets/font.ttf', False), ('ca', 'assets/ca.pem', False)):
            t.create(name, content(self.frozen.spec['pins'][key]['path']), execute=execute)
        helper = t.path('assets/vela-lifecycle-child')
        t.create('owner.json', json.dumps({'root': t.root, 'nonce': self.nonce, 'case': self.case}).encode())
        settings = {'microsoft_client_id': '', 'curseforge_enabled': False, 'curseforge_terms_approved': False,
                    'curseforge_credential_ref': None,
                    'game_exit_behavior': 'exit_launcher' if self.case in ('exit_together', 'abnormal') else 'restore_launcher'}
        config = {'schema_version': 1, 'settings': settings, 'instances': [], 'servers': [],
                  'accounts': [{'id': 'lifecycle-offline', 'kind': 'offline', 'name': 'LifecyclePlayer',
                                'uuid': '11111111111111111111111111111111', 'credential_ref': None}],
                  'selected_instance': 'lifecycle-world', 'selected_account': 'lifecycle-offline', 'selected_server': None}
        jar = b'PK\x03\x04controlled-native-process-fixture'
        for identifier, name in (('lifecycle-world', 'selectedWorld'), ('lifecycle-game', 'ControlledGame')):
            config['instances'].append({'id': identifier, 'name': name, 'minecraft_version': 'lifecycle-local',
                'loader': 'vanilla', 'java_path': helper, 'debug_launch': self.case == 'debug' and identifier == 'lifecycle-game'})
            t.mkdir('.minecraft/versions/' + name)
            t.mkdir('.minecraft/versions/' + name + '/saves')
            t.mkdir('.minecraft/versions/' + name + '/natives')
            metadata = {'id': name, 'mainClass': 'vela.lifecycle.ControlledGame',
                'javaVersion': {'component': 'java-runtime', 'majorVersion': 21},
                'arguments': {'jvm': ['-Djava.library.path=${natives_directory}', '-cp', '${classpath}'], 'game': []},
                'assetIndex': {'id': 'lifecycle-local', 'url': 'https://lifecycle.invalid/assets'},
                'downloads': {'client': {'url': 'https://lifecycle.invalid/client', 'size': len(jar), 'sha1': hashlib.sha1(jar).hexdigest()}}, 'libraries': []}
            t.create('.minecraft/versions/' + name + '/' + name + '.json', json.dumps(metadata).encode())
            t.create('.minecraft/versions/' + name + '/' + name + '.jar', jar)
        t.create('.minecraft/assets/indexes/lifecycle-local.json', b'{"objects":{}}')
        t.create('.vela/config.json', json.dumps(config).encode())
        architecture = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'i386': 'x86', 'i686': 'x86', 'aarch64': 'aarch64', 'arm64': 'aarch64'}[os.uname().machine.lower()]
        t.create('.vela/java.json', json.dumps({'version': 3,
            'runtimes': [{'path': helper, 'major': 21, 'vendor': 'Vela Lifecycle Fixture', 'architecture': architecture}],
            'hidden': []}).encode())
        t.create('ipc/command.json', json.dumps({'nonce': self.nonce, 'sequence': 0, 'kind': 'none'}).encode(), mutable=True)
        t.create('ipc/status.json', b' ' * (64 * 1024), mutable=True)
        for name in ('probe.json', 'game.json'):
            t.create('ipc/' + name, b' ' * (16 * 1024), mutable=True)
        for name in ('world-release', 'probe-release', 'game-release'):
            t.create('ipc/' + name, mutable=True)
        t.create('runtime/wayvnc.conf')
        t.create('evidence/freeze.json', content(self.frozen.path))
        self.immutable = {name: hashlib.sha256(t.read(name)).hexdigest() for name in t.fds if name not in t.mutable}
        t.create('evidence/fixture-pins.json', json.dumps(self.immutable, indent=2).encode())
        self.immutable['evidence/fixture-pins.json'] = hashlib.sha256(t.read('evidence/fixture-pins.json')).hexdigest()
        self.immutable_stamps = {name: stamp(os.fstat(t.fds[name])) for name in self.immutable}
        python = self.frozen.spec['pins']['python']['path']
        self.env = {'PATH': os.path.dirname(python), 'HOME': t.path('home'), 'LANG': 'C.UTF-8',
            'XDG_RUNTIME_DIR': self.runtime, 'XDG_DATA_HOME': t.path('xdg/data'), 'XDG_CONFIG_HOME': t.path('xdg/config'),
            'XDG_CACHE_HOME': t.path('xdg/cache'), 'XDG_STATE_HOME': t.path('xdg/state'),
            'WLR_BACKENDS': 'headless', 'WLR_RENDERER': 'pixman', 'WLR_HEADLESS_OUTPUTS': '1',
            'SDL_VIDEO_DRIVER': 'wayland', 'SDL_RENDER_DRIVER': 'opengl', 'LIBGL_ALWAYS_SOFTWARE': '1',
            # GTK exits the process on compositor loss before SDL can unwind.
            # Use SDL's supported Cairo/dummy libdecor fallback in this fixture.
            'SDL_ENABLE_GTK': '0' if self.case == 'ordinary_destroy' else '1',
            'WAYLAND_DEBUG': 'client',
            'LD_LIBRARY_PATH': ':'.join(LIBRARIES),
            'GDK_BACKEND': 'wayland',
            'DBUS_SESSION_BUS_ADDRESS': 'unix:path=' + self.runtime + '/no-session-bus',
            'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=' + self.runtime + '/no-system-bus',
            'AT_SPI_BUS_ADDRESS': 'unix:path=' + self.runtime + '/no-atspi-bus',
            'NO_AT_BRIDGE': '1', 'GTK_USE_PORTAL': '0', 'GIO_USE_VFS': 'local',
            'VELA_DATA_DIR': t.root, 'VELA_FONT_PATH': t.path('assets/font.ttf'), 'VELA_LIFECYCLE_ROOT': t.root,
            'VELA_LIFECYCLE_NONCE': self.nonce, 'VELA_LIFECYCLE_CASE': self.case, 'VELA_LIFECYCLE_HELPER': helper,
            'VELA_LIFECYCLE_CA': t.path('assets/ca.pem')}
        for key, name in (('HELPER', 'assets/vela-lifecycle-child'), ('FONT', 'assets/font.ttf'),
                           ('CA', 'assets/ca.pem'), ('CONFIG', '.vela/config.json'), ('JAVA', '.vela/java.json')):
            self.env['VELA_LIFECYCLE_' + key + '_SHA256'] = self.immutable[name]

    def parent(self, pid):
        with open('/proc/' + str(pid) + '/stat', encoding='ascii') as stream:
            raw = stream.read(4096)
        return int(raw[raw.rfind(')') + 2:].split()[1])

    def remember(self, role, pid, executable, parent, session):
        current = self.h.identity(pid)
        require(current['exe'] == executable and self.parent(pid) == parent, 'Wrong owned executable/ancestry: ' + role)
        require(current['sid'] == current['pgid'] == session, 'Wrong owned process session')
        fd = os.pidfd_open(pid, 0)
        require(self.h.identity(pid) == current, 'PID identity raced pidfd')
        self.processes[role] = {'identity': current, 'pidfd': fd, 'parent': parent}
        self.events.append({'event': 'identity', 'role': role, 'identity': current})
        return current

    def exited(self, role):
        return bool(select.select([self.processes[role]['pidfd']], [], [], 0)[0])

    def launch(self, role, argv, executable, pass_fds=(), output=None):
        self.guard()
        stdout = self.tree.create('evidence/' + role + '.stdout', mutable=True) if output is None else output
        stderr = self.tree.create('evidence/' + role + '.stderr', mutable=True)
        child = subprocess.Popen(argv, env=self.env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                 start_new_session=True, pass_fds=pass_fds)
        self.jobs[role] = child
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            require(child.poll() is None, 'Process exited before identity pin: ' + role)
            try:
                if self.h.identity(child.pid)['exe'] == executable:
                    return self.remember(role, child.pid, executable, os.getpid(), child.pid)
            except (FileNotFoundError, ProcessLookupError):
                pass
            time.sleep(0.001)
        raise RuntimeError('Cannot bind owned executable: ' + role)

    def guard(self):
        probe_critical = self.probe_deadline is not None
        if probe_critical:
            require(time.monotonic() < self.probe_deadline, 'Lifecycle driver exceeded probe barrier budget')
        self.frozen.guard(probe_critical=probe_critical)
        self.tree.guard()
        for name, digest in self.immutable.items():
            require(stamp(os.fstat(self.tree.fds[name])) == self.immutable_stamps[name] and
                    stamp(os.stat(self.tree.path(name), follow_symlinks=False)) == self.immutable_stamps[name],
                    'Fixture immutable bytes drift: ' + name)
            if not probe_critical:
                require(hashlib.sha256(self.tree.read(name)).hexdigest() == digest, 'Fixture immutable drift: ' + name)
        alive = []
        for role, row in self.processes.items():
            if self.exited(role):
                continue
            try:
                current = self.h.identity(row['identity']['pid'])
                parent_matches = self.parent(current['pid']) == row['parent']
                if role == 'gui' and self.case == 'ordinary_destroy' and self.exited('cage'):
                    parent_matches |= self.parent(current['pid']) in (1, os.getpid())
            except (FileNotFoundError, ProcessLookupError):
                if self.exited(role):
                    self.events.append({'event': 'terminal-during-identity-read', 'role': role})
                    continue
                raise
            require(current == row['identity'] and parent_matches, 'Live owned identity drift: ' + role)
            alive.append(current)
        self.h.tcp_owned(alive + [self.h.identity(os.getpid())])
        if 'cage' in self.processes and not self.exited('cage'):
            leader = self.processes['cage']['identity']['pid']
            approved = {row['identity']['pid']: row['identity'] for row in self.processes.values()}
            for row in self.h.members(leader):
                if row['pid'] in approved:
                    pinned = approved[row['pid']]
                    require(all(row[key] == pinned[key] for key in ('pid', 'start', 'pgid', 'sid')), 'Recorded descendant identity drift')
                else:
                    require(self.gui is not None and not row.get('zombie') and
                            row['exe'] == self.tree.path('assets/vela-lifecycle-child') and
                            self.parent(row['pid']) == self.gui['pid'], 'Unapproved Cage descendant')
                    self.remember('helper-' + str(row['pid']), row['pid'], row['exe'], self.gui['pid'], leader)
    def status(self):
        self.guard()
        try:
            value = decode(self.tree.read('ipc/status.json', 64 * 1024))
        except (ValueError, UnicodeDecodeError):
            return None  # A pinned regular inode may hold a partial frame write.
        require(value['nonce'] == self.nonce and value['case'] == self.case and value['sequence'] <= self.sequence,
                'Foreign/unsent status')
        if not self.history or self.history[-1] != value:
            self.history.append(value)
        return value

    def wait(self, predicate, label, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = self.status()
            if value is not None and predicate(value):
                self.events.append({'event': 'observed', 'label': label, 'status': value})
                return value
            if self.gui is not None and self.exited('gui'):
                raise RuntimeError('GUI exited before ' + label)
            time.sleep(0.02)
        raise RuntimeError('Timed out: ' + label)

    def command(self, kind):
        self.guard()
        self.sequence += 1
        self.tree.write('ipc/command.json', json.dumps({'nonce': self.nonce, 'sequence': self.sequence, 'kind': kind}).encode())
        self.wait(lambda v: v['sequence'] == self.sequence, 'command-' + kind)

    def release(self, role):
        self.guard()
        if role == 'probe':
            require(self.probe_deadline is not None and time.monotonic() < self.probe_deadline,
                    'Probe release guard exceeded barrier budget')
        self.tree.write('ipc/' + role + '-release', self.nonce.encode())
        event = {'event': 'release', 'role': role}
        if role == 'probe':
            released = time.monotonic()
            event['elapsed_seconds'] = 1.75 - (self.probe_deadline - released)
            event['budget_seconds'] = 1.75
            self.events.append(event)
            require(released < self.probe_deadline, 'Probe release write exceeded barrier budget')
        else:
            self.events.append(event)

    def marker(self, role):
        try:
            value = decode(self.tree.read('ipc/' + role + '.json', 16 * 1024))
        except (ValueError, UnicodeDecodeError):
            return None
        require(value['nonce'] == self.nonce and value['role'] == role, 'Foreign helper marker')
        require(role != 'probe' or value['ready'] is False, 'Probe emitted game Ready')
        return value

    def bind(self, role):
        deadline = self.probe_deadline if role == 'probe' else time.monotonic() + 15
        require(deadline is not None, 'Probe binding requires bounded barrier window')
        while time.monotonic() < deadline:
            self.guard()
            value = self.marker(role)
            if value is not None:
                self.remember(role, value['pid'], self.tree.path('assets/vela-lifecycle-child'),
                              self.gui['pid'], self.processes['cage']['identity']['pid'])
                return value
            time.sleep(0.01)
        raise RuntimeError('No owned helper marker: ' + role)

    def imports(self):
        for module in tuple(sys.modules.values()):
            path = getattr(module, '__file__', None)
            if path:
                target = os.path.realpath(path)
                approved = self.frozen.abi.get(target) or next((row for row in self.frozen.files if row['path'] == target), None)
                require(approved is not None, 'Unfrozen Python ABI/import: ' + target)
                verify(approved, full=self.probe_deadline is None)

    def pin_socket(self, path, mode):
        original = os.stat(path, follow_symlinks=False)
        require(stat.S_ISSOCK(original.st_mode) and original.st_uid == os.getuid(),
                'Foreign owned socket')
        require(path not in self.socket_fds, 'Socket already pinned')
        fd = os.open(path, os.O_PATH | NOFOLLOW)
        try:
            require(node(os.fstat(fd)) == node(original), 'Socket open raced')
            # Change only the checked inode, even if its pathname is replaced.
            os.chmod('/proc/self/fd/' + str(fd), mode)
            actual = os.stat(path, follow_symlinks=False)
            require(node(actual) == node(os.fstat(fd)) and
                    node(actual)[:-1] == node(original)[:-1] and
                    stat.S_IMODE(actual.st_mode) == mode, 'Socket identity/mode drift')
            self.socket_pins[path] = node(actual)
            self.socket_fds[path] = fd
        except BaseException:
            os.close(fd)
            raise

    def input_guard(self):
        self.guard()
        require(not self.exited('gui') and not self.exited('cage'), 'No live owned input target')
        for path, expected in self.socket_pins.items():
            require(node(os.stat(path, follow_symlinks=False)) ==
                    node(os.fstat(self.socket_fds[path])) == expected, 'Owned socket identity drift')
        self.imports()

    def start(self):
        tools = self.frozen.spec['pins']['tools']
        cage = self.launch('cage', [tools['cage']['path'], '-D', '--', self.tree.path('assets/vela-lifecycle-acceptance')], tools['cage']['path'])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            for row in self.h.members(cage['pid']):
                if not row.get('zombie') and row['exe'] == self.tree.path('assets/vela-lifecycle-acceptance'):
                    self.gui = self.remember('gui', row['pid'], row['exe'], cage['pid'], cage['pid'])
                    break
            if self.gui:
                break
            time.sleep(0.01)
        require(self.gui is not None, 'No production App under Cage')
        self.socket_pins = {}
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sockets = [p for p in Path(self.runtime).glob('wayland-*') if not p.name.endswith('.lock') and
                       stat.S_ISSOCK(p.stat(follow_symlinks=False).st_mode)]
            if len(sockets) == 1:
                self.pin_socket(str(sockets[0]), 0o700)
                self.env['WAYLAND_DISPLAY'] = sockets[0].name
                break
            time.sleep(0.01)
        require('WAYLAND_DISPLAY' in self.env, 'No sole owned Wayland socket')
        config_fd = self.tree.fds['runtime/wayvnc.conf']
        self.launch('wayvnc', [tools['wayvnc']['path'], '-u', self.runtime + '/rfb.sock', '-S', self.runtime + '/control.sock',
                              '-o', 'HEADLESS-1', '-C', '/proc/self/fd/' + str(config_fd)], tools['wayvnc']['path'], pass_fds=(config_fd,))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not os.path.exists(self.runtime + '/rfb.sock'):
            self.guard()
            time.sleep(0.02)
        for name in ('rfb.sock', 'control.sock'):
            path = self.runtime + '/' + name
            self.pin_socket(path, 0o600)
        runpy.run_path(tools['vncdotool']['path'], run_name='standard_bootstrap')
        from vncdotool import api
        from vncdotool.command import parse_server
        address = self.runtime + '/rfb.sock'
        require(parse_server(address)[0] == socket.AF_UNIX, 'Input must be AF_UNIX')
        self.api, self.client = api, api.connect(address, timeout=5)
        self.imports()
        self.wait(lambda v: v.get('ready') and v['task_count'] == v['active_background'] == 0 and
                  v['panel'] == 'home' and not v['hidden'], 'production-startup-ready')
        self.materialize_keyboard()
        self.capture('ready')

    def keyboard_trace(self):
        raw = self.tree.read('evidence/cage.stderr', 16 * 1024 * 1024).decode(errors='replace')
        surfaces = set(re.findall(r'get_xdg_surface\(new id xdg_surface[#@]\d+, wl_surface[#@](\d+)\)', raw))
        require(len(surfaces) == 1, 'Owned App must have one traced toplevel surface')
        lines = [line for line in raw.splitlines() if re.search(r'wl_keyboard[#@]\d+\.(enter|leave|key|modifiers)\(', line)]
        focused = None
        for line in lines:
            entered = re.search(r'\.enter\(\d+, wl_surface[#@](\d+),', line)
            if entered:
                focused = entered.group(1)
            elif '.leave(' in line:
                focused = None
        return focused in surfaces, lines

    def keyboard_wait(self, predicate, label):
        deadline = time.monotonic() + (0.3 if self.probe_deadline is not None else 5)
        while time.monotonic() < deadline:
            self.guard()
            focused, lines = self.keyboard_trace()
            if predicate(focused, lines):
                self.events.append({'event': 'native-keyboard-observed', 'label': label, 'trace': lines[-12:]})
                return lines
            if self.exited('gui'):
                break
            time.sleep(0.01)
        raise RuntimeError('Native keyboard delivery unproved: ' + label)

    def materialize_keyboard(self):
        self.input_guard()
        self.client.mouseMove(32, 32)
        self.client.keyDown('shift')
        try:
            self.keyboard_wait(lambda focused, _: focused, 'startup-owned-surface-focus')
        finally:
            self.client.keyUp('shift')
        self.client.pause(0.1)

    def close_input(self):
        self.input_guard()
        self.keyboard_wait(lambda focused, _: focused, 'close-owned-surface-focus')
        _, prior = self.keyboard_trace()
        offset = len(prior)
        surface = re.findall(r'\.enter\(\d+, wl_surface[#@](\d+),', '\n'.join(prior))[-1]
        def key_delivered(lines, code):
            keyboards = {}
            for index, line in enumerate(lines):
                record = re.search(r'wl_keyboard[#@](\d+)\.(enter|leave|key|modifiers)\((.*)\)', line)
                if not record:
                    continue
                keyboard, kind, args = record.groups()
                state = keyboards.setdefault(keyboard, {'surface': None, 'modifiers': 0, 'alt_down': False})
                if kind == 'enter':
                    entered = re.search(r'wl_surface[#@](\d+)', args)
                    state['surface'] = entered.group(1) if entered else None
                elif kind == 'leave':
                    state['surface'] = None
                    state['alt_down'] = False
                elif kind == 'modifiers':
                    state['modifiers'] = int(args.split(',')[1])
                elif kind == 'key':
                    fields = [int(field.strip()) for field in args.split(',')]
                    if fields[2] == 56:
                        state['alt_down'] = fields[3] == 1
                    if index >= offset and fields[2:] == [code, 1] and state['surface'] == surface:
                        if state['alt_down'] and state['modifiers'] != 0:
                            return True
            return False
        try:
            self.client.keyDown('alt')
            self.keyboard_wait(lambda focused, lines: focused and key_delivered(lines, 56), 'alt-down')
            self.client.keyDown('f4')
            self.keyboard_wait(lambda _, lines: key_delivered(lines, 62), 'f4-down')
            self.events.append({'event': 'native-close-chord-delivered', 'route': 'launcher-close-shortcut'})
        finally:
            for key in ('f4', 'alt'):
                try:
                    self.client.keyUp(key)
                except Exception as exc:
                    self.events.append({'event': 'input-release-after-close', 'key': key, 'error': str(exc)})

    def choose(self, choice):
        previous_geometry, previous_frame = None, None
        def drawn_dialog_ready(value):
            nonlocal previous_geometry, previous_frame
            if value.get('shutdown') != 'prompt':
                return False
            layout = value.get('shutdown_layout')
            if not isinstance(layout, dict):
                return False
            names = ('viewport', 'modal', 'clip', 'wait', 'cancel_and_quit', 'keep_open')
            for name in names:
                candidate = layout.get(name)
                if not isinstance(candidate, dict) or not all(
                    isinstance(candidate.get(key), (int, float)) and not isinstance(candidate.get(key), bool)
                    and math.isfinite(candidate[key]) for key in ('x', 'y', 'w', 'h')):
                    return False
                if candidate['w'] <= 0 or candidate['h'] <= 0:
                    return False
            for name in names[3:]:
                rect = layout[name]
                for outer_name in names[:3]:
                    outer = layout[outer_name]
                    if not (rect['x'] >= outer['x'] - 0.01 and rect['y'] >= outer['y'] - 0.01 and
                            rect['x'] + rect['w'] <= outer['x'] + outer['w'] + 0.01 and
                            rect['y'] + rect['h'] <= outer['y'] + outer['h'] + 0.01):
                        return False
            geometry = tuple(layout[name][key] for name in names for key in ('x', 'y', 'w', 'h'))
            frame = value.get('frame')
            ready = geometry == previous_geometry and frame != previous_frame
            previous_geometry, previous_frame = geometry, frame
            return ready
        value = self.wait(drawn_dialog_ready, 'stable-visible-exit-dialog')
        self.capture('dialog-' + choice)
        self.input_guard()
        layout = value.get('shutdown_layout')
        require(isinstance(layout, dict), 'No real shutdown draw geometry')
        rect = layout.get(choice)
        require(isinstance(rect, dict), 'No drawn rectangle for dialog choice: ' + choice)
        def bounds(candidate, label):
            require(isinstance(candidate, dict) and all(
                isinstance(candidate.get(key), (int, float)) and not isinstance(candidate.get(key), bool)
                and math.isfinite(candidate[key]) for key in ('x', 'y', 'w', 'h')),
                'Invalid drawn dialog geometry: ' + label)
            require(candidate['w'] > 0 and candidate['h'] > 0, 'Empty drawn dialog geometry: ' + label)
            return candidate
        rect = bounds(rect, choice)
        for name in ('viewport', 'modal', 'clip'):
            outer = bounds(layout.get(name), name)
            require(rect['x'] >= outer['x'] and rect['y'] >= outer['y'] and
                    rect['x'] + rect['w'] <= outer['x'] + outer['w'] + 0.01 and
                    rect['y'] + rect['h'] <= outer['y'] + outer['h'] + 0.01,
                    'Drawn dialog choice is clipped by ' + name)
        x, y = int(rect['x'] + rect['w'] / 2), int(rect['y'] + rect['h'] / 2)
        self.client.mouseMove(x, y)
        self.client.pause(0.1)
        self.input_guard()
        self.client.mousePress(1)
        self.events.append({'event': 'input', 'choice': choice, 'x': x, 'y': y,
                            'source': 'actual-drawn-button-rectangle', 'layout': layout})
        self.wait(lambda v: v.get('close_choice') == choice, 'actual-visible-dialog-choice')

    def capture(self, label):
        self.input_guard()
        fd = self.tree.create('evidence/' + label + '.png', mutable=True)
        role = 'grim-' + label
        tool = self.frozen.spec['pins']['tools']['grim']['path']
        self.launch(role, [tool, '-o', 'HEADLESS-1', '-'], tool, output=fd)
        self.jobs[role].wait(timeout=10)
        require(self.jobs[role].returncode == 0 and self.exited(role), 'Owned screenshot helper not reaped cleanly')
        require(self.tree.read('evidence/' + label + '.png').startswith(b'\x89PNG\r\n\x1a\n'), 'No real screenshot')

    def held_world(self):
        self.command('arm_world')
        self.wait(lambda v: v.get('world_entered') and v['world']['worker_active'] and v['active_background'] > 0,
                  'real-held-world-worker')

    def continued(self, predicate, label):
        value = self.wait(predicate, label)
        # Each sample includes full closure/process guards, so allow four observations under load.
        observation_seconds = 0.45 if self.probe_deadline is not None else 2.0
        deadline, samples = time.monotonic() + observation_seconds, 0
        last_frame = value['frame']
        while time.monotonic() < deadline:
            current = self.status()
            if current:
                require(predicate(current), 'Unstable continued-frame proof: ' + label)
                require(current['frame'] >= last_frame, 'Lifecycle frame counter regressed')
                if current['frame'] > last_frame:
                    samples += 1
                    last_frame = current['frame']
            time.sleep(0.025)
        require(samples >= 4, f"Insufficient continued frames: {label}; samples={samples}; "
                f"start_frame={value['frame']}; last_frame={last_frame}")
        return value

    def reap(self, role):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.guard()
            if self.exited(role) and not os.path.exists('/proc/' + str(self.processes[role]['identity']['pid'])):
                self.events.append({'event': 'terminal-and-reaped', 'role': role})
                return
            time.sleep(0.02)
        raise RuntimeError('Child terminal/reap unproved: ' + role)

    def gui_exit(self):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = self.status()
            if self.exited('gui') and value and value.get('destroyed'):
                require(value['world_joined'] and value['accounts_joined'], 'Real manager JOIN evidence missing')
                self.jobs['cage'].wait(timeout=10)
                self.reap('gui')
                require(not self.h.members(self.processes['cage']['identity']['pid']), 'Cage session still present')
                return value
            time.sleep(0.02)
        raise RuntimeError('GUI exit/deinit/JOIN unproved')

    def exercise(self):
        self.start()
        case = self.case
        if case in ('idle_keep', 'idle_auxiliary', 'idle_cancel', 'ordinary_destroy', 'exit_together'):
            self.held_world()
        if case.startswith('idle_'):
            self.close_input()
            if case != 'idle_auxiliary':
                self.choose({'idle_keep': 'keep_open', 'idle_cancel': 'cancel_and_quit'}[case])
            if case in ('idle_cancel', 'idle_auxiliary'):
                self.continued(lambda v: v.get('shutdown') == 'canceling' and v['hidden'] and v['world']['worker_active'] and
                               v.get('cleanup_entered') and not v.get('cleanup_returned') and not v.get('destroy_entered'),
                               'hidden-cleanup-held-after-real-cancel')
            else:
                self.continued(lambda v: v.get('shutdown') == 'none' and not v['hidden'] and v['world']['worker_active'],
                               'keep-open-retains-window-worker')
            self.release('world')
            if case == 'idle_keep':
                self.wait(lambda v: v.get('cleanup_returned') and not v['world']['worker_active'] and
                          v['active_background'] == v['task_count'] == 0 and not v['accounts']['busy'], 'posttick-inactive-after-JOIN')
                self.close_input()
            self.gui_exit()
            return
        if case == 'ordinary_destroy':
            # Actual compositor shutdown, never an invented SDL Quit/EndEvent.
            # If the backend does not enter ordinary App deinit this case fails.
            self.send('cage', signal.SIGTERM)
            self.wait(lambda v: v.get('destroy_entered') and not v.get('world_joined'), 'ordinary-deinit-held-at-JOIN')
            self.release('world')
            self.gui_exit()
            return
        self.guard()
        self.probe_deadline = time.monotonic() + 1.75
        try:
            self.command('start')
            probe = self.bind('probe')
            require(probe['held'], 'Real probe identity barrier absent')
            if case == 'close_preparing':
                self.wait(lambda v: v['game']['phase'] == 'preparing', 'real-preparing')
                self.close_input()
                self.continued(lambda v: v['hidden'] and v['game']['phase'] == 'preparing' and
                               v['policy_game'] == 'preparing' and not self.exited('probe'), 'close-keeps-preparing-probe')
            self.release('probe')
        finally:
            self.probe_deadline = None
        self.guard()
        ready = self.bind('game')
        require(ready['ready'] is True and ready['cwd'] == self.tree.path('.minecraft/versions/ControlledGame'), 'Wrong game Ready/cwd')
        self.reap('probe')
        self.wait(lambda v: v['game']['phase'] == 'running', 'real-game-running')
        if case == 'close_running':
            self.close_input()
            self.continued(lambda v: v['hidden'] and v['game']['phase'] == 'running' and not self.exited('game'),
                           'real-close-keeps-child-running')
        elif case == 'debug':
            self.continued(lambda v: not v['hidden'] and v['panel'] == 'logs' and v['game']['phase'] == 'running', 'visible-debug-logs')
            self.capture('debug-logs')
            self.close_input()
            self.continued(lambda v: v['hidden'] and v['game']['phase'] == 'running' and not self.exited('game'), 'debug-close-keeps-child')
        else:
            self.continued(lambda v: v['hidden'] and v['game']['phase'] == 'running' and not self.exited('game'), 'ordinary-hide-keeps-child')
        require(self.marker('game')['ticks'] > ready['ticks'], 'No continued real heartbeat while hidden')
        self.release('game')
        if case == 'exit_together':
            self.wait(lambda v: v.get('shutdown') == 'prompt' and v['world']['worker_active'], 'auto-exit-prompts-for-unrelated-world')
            self.choose('cancel_and_quit')
            self.wait(lambda v: v.get('shutdown') == 'canceling' and v.get('cleanup_entered') and
                      not v.get('cleanup_returned') and v['world']['worker_active'], 'auto-exit-held-by-unrelated-world')
            self.reap('game')
            self.release('world')
            require(self.gui_exit()['cleanup_returned'], 'World released before cleanup return')
        else:
            expected_phase = 'failed' if case == 'abnormal' else 'exited'
            end = self.wait(lambda v: v['game']['phase'] == expected_phase and not v['hidden'] and v['policy_game'] == 'idle', 'restored-after-game-exit')
            require(end['game']['exit_code'] == (7 if case == 'abnormal' else 0), 'Wrong actual child exit code')
            require(end['game']['failure'] == ('GameProcessFailed' if case == 'abnormal' else None), 'Wrong actual child failure state')
            if case == 'abnormal':
                require(end['panel'] == 'logs' and not end['actions']['quit'], 'Exit7 failed to override exit preference')
                self.capture('abnormal-logs')
            self.reap('game')
            self.close_input()
            self.gui_exit()
        self.capture_logs()

    def capture_logs(self):
        stdout = stderr = False
        for path in Path(self.tree.path('.vela/logs')).glob('*.log'):
            data = content(str(path))
            stdout |= ('LIFECYCLE_GAME_READY ' + self.nonce).encode() in data
            stderr |= ('LIFECYCLE_GAME_STDERR ' + self.nonce).encode() in data
        require(stdout and stderr, 'Real stdout/stderr nonce evidence absent')
        self.events.append({'event': 'real-stdout-stderr-captured'})

    def send(self, role, number):
        if self.exited(role):
            return
        row = self.processes[role]
        try:
            require(self.h.identity(row['identity']['pid']) == row['identity'], 'Refuse signal after identity drift')
            signal.pidfd_send_signal(row['pidfd'], number)
        except (FileNotFoundError, ProcessLookupError):
            if self.exited(role):
                self.events.append({'event': 'terminal-during-owned-signal', 'role': role})
                return
            raise
        self.events.append({'event': 'owned-pidfd-signal', 'role': role, 'signal': number})

    def cleanup(self):
        problems = []
        for name in ('world-release', 'probe-release', 'game-release'):
            try:
                self.tree.write('ipc/' + name, self.nonce.encode())
            except Exception as exc:
                problems.append('Owned release: ' + str(exc))
        if self.client:
            try:
                self.client.disconnect()
                self.api.shutdown()
            except Exception as exc:
                self.events.append({'event': 'input-cleanup-note', 'error': str(exc)})
        for role in reversed(tuple(self.processes)):
            try:
                if not self.exited(role):
                    self.send(role, signal.SIGTERM)
                    if not select.select([self.processes[role]['pidfd']], [], [], 2)[0]:
                        self.send(role, signal.SIGKILL)
                        require(select.select([self.processes[role]['pidfd']], [], [], 2)[0], 'Owned process still live')
            except Exception as exc:
                problems.append(role + ': ' + str(exc))
        for role, child in self.jobs.items():
            try:
                child.wait(timeout=5)
            except Exception as exc:
                problems.append(role + ' reap: ' + str(exc))
        for role, row in self.processes.items():
            if os.path.exists('/proc/' + str(row['identity']['pid'])):
                problems.append(role + ' PID remains; identity reuse is not assumed')
        for role in ('cage', 'wayvnc'):
            if role in self.processes and self.h.members(self.processes[role]['identity']['pid']):
                problems.append(role + ' session/group remains')
        try:
            self.tree.guard()
            if not problems:
                for path in Path(self.runtime).iterdir():
                    s = path.stat(follow_symlinks=False)
                    if stat.S_ISSOCK(s.st_mode):
                        expected = getattr(self, 'socket_pins', {}).get(str(path))
                        require(expected is not None and node(s) == expected and s.st_uid == os.getuid(), 'Unrecorded/foreign leftover socket')
                        os.unlink(path.name, dir_fd=self.tree.dirs['runtime'][0])
                require(not self.h.unix_entries(self.tree.root), 'Owned Unix listener remains')
                self.h.tcp_owned([self.h.identity(os.getpid())])
            self.frozen.guard(full=True)
        except Exception as exc:
            problems.append('Final ownership/listener proof: ' + str(exc))
        return problems

    def report(self, error, problems):
        result = {'case': self.case, 'root': self.tree.root, 'nonce': self.nonce, 'passed': error is None and not problems,
                  'error': error, 'cleanup_problems': problems, 'events': self.events, 'frames': self.history,
                  'limits': ['controlled native helper, not JVM/Minecraft gameplay', 'IPC Start is not Home Start UI admission',
                             'world/account teardown evidence only, not universal manager JOIN', 'headless compositor, not real desktop/GPU']}
        self.tree.create('evidence/result.json', json.dumps(result, indent=2).encode())
        for row in self.processes.values():
            os.close(row['pidfd'])
        for fd in self.socket_fds.values():
            os.close(fd)
        self.socket_fds.clear()
        self.tree.close()
        print(json.dumps({key: result[key] for key in ('passed', 'case', 'root', 'error', 'cleanup_problems')}))
        return result['passed']


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('freeze')
    builder.add_argument('--pins', required=True)
    builder.add_argument('--output', required=True)
    runner = commands.add_parser('run')
    runner.add_argument('--freeze', required=True)
    runner.add_argument('--case', choices=CASES, required=True)
    runner.add_argument('--root', required=True)
    args = parser.parse_args()
    if args.command == 'freeze':
        freeze(args)
        return
    frozen = Frozen(args.freeze)
    try:
        run = Run(frozen, args.root, args.case)
        error = None
        try:
            run.exercise()
        except Exception as exc:
            error = str(exc)
        problems = run.cleanup()
        require(run.report(error, problems), 'Lifecycle acceptance failed; owned evidence retained')
    finally:
        frozen.close()


if __name__ == '__main__':
    main()
