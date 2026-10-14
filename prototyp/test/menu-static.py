#!/usr/bin/env python3
"""Analiza statyczna akcji menu Omarchy: które akcje (śledzone przez skrypty omarchy-* do
głębokości 2) wciąż sięgają po narzędzia, których warstwa portu na Voidzie nie pokrywa.
Użycie: menu-static.py <omarchy-src> <menu-akcje.json>  →  TSV na stdout + podsumowanie na stderr.
Wynik to PODEJRZENIE do weryfikacji na żywo, nie dowód — skrypt może mieć gałąź alternatywną."""
import json, os, re, sys, collections

src, actions_path = sys.argv[1], sys.argv[2]
binp = os.path.join(src, "bin")

# Brakujące na Voidzie i NIEpokryte przez warstwę portu (sprawdzone w VM 14.10)
UNCOVERED = {
    "pacman/AUR": r"\b(pacman|yay|paru|makepkg|expac|checkupdates|paccache|pactree)\b",
    "limine/snapper/mkinitcpio": r"\b(limine[\w-]*|snapper|mkinitcpio)\b",
    "journalctl/coredumpctl": r"\b(journalctl|coredumpctl)\b",
    "timedatectl/hostnamectl/localectl": r"\b(timedatectl|hostnamectl|localectl)\b",
    "resolvectl/networkctl": r"\b(resolvectl|networkctl)\b",
    "systemd-tmpfiles/sysusers": r"\b(systemd-tmpfiles|systemd-sysusers)\b",
    "uwsm (nie uwsm-app)": r"\buwsm(?!-app)\b",
    "iwd (iwctl/impala)": r"\b(iwctl|impala)\b",
}
# Pokryte przez warstwę (dla informacji)
COVERED = r"\b(systemctl|systemd-run|systemd-cat|systemd-inhibit|uwsm-app|xdg-terminal-exec|omarchy-pkg-[a-z-]+)\b"

# Skrypty Omarchy podmienione nakładkami portu (port/bin) — nie wchodzimy w ich upstreamową treść
OVERRIDDEN = {f for f in os.listdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'port', 'bin')) if f.startswith('omarchy-')}

cache = {}
def script(name):
    if name not in cache:
        p = os.path.join(binp, name)
        try:
            cache[name] = open(p, errors="ignore").read() if os.path.isfile(p) else ""
        except OSError:
            cache[name] = ""
    return cache[name]

def strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

def reach(cmd, depth=2):
    seen, frontier, texts = set(), set(re.findall(r"\bomarchy-[a-z0-9-]+", cmd)), [cmd]
    for _ in range(depth):
        nxt = set()
        for n in frontier - seen:
            seen.add(n)
            if n in OVERRIDDEN:
                continue  # na porcie podmienione nakładką — upstreamowa treść (pacman) nie działa
            t = strip_comments(script(n))
            texts.append(t)
            nxt |= set(re.findall(r"\bomarchy-[a-z0-9-]+", t))
        frontier = nxt
    return "\n".join(texts)

acts = json.load(open(actions_path))
danger = re.compile(r"reboot|shutdown|poweroff|suspend|hibernate|logout|uwsm stop|system-lock|factory|reset|remove|uninstall|drop|update|install|delete|wipe|format|reinstall|-set |dev-|refresh|restart|toggle-|passwd|sudo|tailscale|dropbox|docker|vpn|fingerprint|fido", re.I)
summary = collections.Counter()
print("id\tetykieta\tniepokryte\takcja")
for d in acts:
    if not danger.search(d["action"]):
        continue
    text = reach(d["action"])
    hits = [k for k, p in UNCOVERED.items() if re.search(p, text)]
    aur = "omarchy-pkg-aur-" in text
    if aur:
        hits.append("AUR (warstwa: uczciwa odmowa)")
    for h in hits:
        summary[h] += 1
    if not hits:
        summary["pokryte warstwą / bez sprzężeń"] += 1
    print("\t".join([d["id"], d.get("label", ""), ", ".join(hits) or "-", d["action"][:120]]))
for k, v in summary.most_common():
    print(f"{v:4d}  {k}", file=sys.stderr)
