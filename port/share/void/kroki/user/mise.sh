# shellcheck shell=bash
# omarchy-port (Void): upstreamowy krok user/mise.sh z jedną różnicą.
# mise z repo Voida (2026.8.2) nie zna ustawienia upgrade.auto_prune (doszło później), więc
# `mise settings set` pada i z nim cały omarchy-provision-user. W tej wersji `mise up` usuwa starą
# wersję od razu i wyłącza to wyłącznie flaga `--no-prune` — ścieżka aktualizacji portu musi jej
# użyć (omarchy-port#3). Gdy Void dostanie nowsze mise, ustawienie zadziała samo.
# omarchy-refresh-applications woła UPSTREAMOWY user/mise.sh wprost (bash bez -e) — tam zostaje
# tylko „mise ERROR Unknown setting” w wyjściu, reszta idzie dalej.
mise() {
  if [[ $* == "settings set upgrade.auto_prune false" ]] && ! command mise settings set upgrade.auto_prune false 2>/dev/null; then
    echo "omarchy-port: mise $(command mise --version | cut -d' ' -f1) nie zna upgrade.auto_prune — pomijam (omarchy-port#3: mise up --no-prune)"
    return 0
  fi
  command mise "$@"
}
source "$OMARCHY_PATH/install/user/mise.sh"
