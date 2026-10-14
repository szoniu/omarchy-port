# omarchy-port: reguły tmpfiles Omarchy przy starcie systemu (runit core-service, sourcowany przez /bin/sh).
# Void nie ma systemd-tmpfiles, a Omarchy przez nie m.in. kasuje przy boocie tymczasowe uprawnienie
# „sudo bez hasła” (omarchy-nopasswd-sudo.conf: `r! /etc/sudoers.d/99-omarchy-nopasswd-*`) — bez tego
# grant z omarchy-sudo-passwordless przeżyłby restart NA STAŁE.
# Obsługiwane typy: r, r!, R, R! (usuń), w, w! (zapisz argument). Inne → komunikat, bez działania.
for _omp_conf in /usr/lib/tmpfiles.d/omarchy*.conf /etc/tmpfiles.d/omarchy*.conf; do
  [ -f "$_omp_conf" ] || continue
  while read -r _omp_type _omp_path _omp_mode _omp_user _omp_group _omp_age _omp_arg; do
    case $_omp_type in
      ''|'#'*) continue ;;
      r|r!) for _omp_f in $_omp_path; do [ -e "$_omp_f" ] && rm -f "$_omp_f"; done ;;
      R|R!) for _omp_f in $_omp_path; do [ -e "$_omp_f" ] && rm -rf "$_omp_f"; done ;;
      w|w!) [ -e "$_omp_path" ] && printf '%s' "$_omp_arg" >"$_omp_path" 2>/dev/null ;;
      *) echo "omarchy-port: tmpfiles typ '$_omp_type' ($_omp_conf) nieobsługiwany" ;;
    esac
  done <"$_omp_conf"
done
unset _omp_conf _omp_type _omp_path _omp_mode _omp_user _omp_group _omp_age _omp_arg _omp_f
