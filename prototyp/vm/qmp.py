#!/usr/bin/env python3
"""Pomocnik QMP dla VM prototypu: klawisze i zrzuty ekranu bez okna.
  qmp.py type 'tekst'        — wpisuje tekst (US), \\n = Enter
  qmp.py key ctrl-alt-f2     — kombinacja klawiszy (qcode-y przez '-')
  qmp.py shot plik.png       — zrzut ekranu (screendump PNG)
  qmp.py cmd '{"execute": …}' — surowe polecenie QMP
"""
import json, socket, sys, time, os

VM_DIR = os.environ.get("VM_DIR", os.path.expanduser("~/vm/omarchy-port"))
_NR = os.environ.get("VM_NR", "1")
SOCK = os.path.join(VM_DIR, "qmp.sock" if _NR == "1" else "qmp%s.sock" % _NR)

def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    f = s.makefile("rw")
    json.loads(f.readline())  # greeting
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    _resp(f)
    return s, f

def _resp(f):
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("QMP: rozłączone")
        msg = json.loads(line)
        if "event" in msg:
            continue
        if "error" in msg:
            raise SystemExit("QMP błąd: %s" % msg["error"])
        return msg.get("return")

def call(f, execute, **arguments):
    req = {"execute": execute}
    if arguments:
        req["arguments"] = arguments
    f.write(json.dumps(req) + "\n"); f.flush()
    return _resp(f)

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal', '{': 'bracket_left',
           '}': 'bracket_right', '|': 'backslash', ':': 'semicolon', '"': 'apostrophe',
           '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
         '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot',
         '/': 'slash', '`': 'grave_accent', '\n': 'ret', '\t': 'tab'}

def char_keys(c):
    if c.isascii() and c.isalpha():
        return (['shift', c.lower()] if c.isupper() else [c])
    if c.isdigit():
        return [c]
    if c in PLAIN:
        return [PLAIN[c]]
    if c in SHIFTED:
        return ['shift', SHIFTED[c]]
    raise SystemExit("nieobsługiwany znak: %r" % c)

def send(f, keys, hold=60):
    call(f, "send-key", keys=[{"type": "qcode", "data": k} for k in keys], **{"hold-time": hold})

def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    op, arg = sys.argv[1], sys.argv[2]
    s, f = connect()
    if op == "type":
        text = arg.encode().decode("unicode_escape")
        for c in text:
            send(f, char_keys(c), hold=30)
            time.sleep(0.02)
    elif op == "key":
        send(f, arg.split("-"))
    elif op == "shot":
        # QEMU działa w kontenerze: $VM_DIR jest tam pod /vm, więc ścieżka
        # względna (od $VM_DIR) zamieniana jest na kontenerową.
        # Przy wyjściu GL (virgl) screendump zwraca 'no surface' — wtedy shot.sh (VNC).
        call(f, "screendump", filename="/vm/" + arg.lstrip("/"), format="png")
    elif op == "click":
        # qmp.py click X,Y — piksele ekranu 1920x1080 → osie tabletu 0..32767
        x, y = (int(v) for v in arg.split(","))
        ev = lambda a, v: {"type": "abs", "data": {"axis": a, "value": v}}
        call(f, "input-send-event", events=[ev("x", x * 32767 // 1920), ev("y", y * 32767 // 1080)])
        for down in (True, False):
            call(f, "input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])
            time.sleep(0.05)
    elif op == "cmd":
        print(json.dumps(_raw(f, arg), indent=1))
    else:
        raise SystemExit(__doc__)
    s.close()

def _raw(f, arg):
    f.write(arg + "\n"); f.flush()
    return _resp(f)

if __name__ == "__main__":
    main()
