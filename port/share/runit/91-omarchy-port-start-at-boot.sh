# omarchy-port: usługi włączone podczas instalacji (`systemctl enable` bez --now w trybie
# OMARCHY_PORT_INSTALL) mają wstać przy następnym starcie systemu, nie w trakcie instalacji —
# jak w systemd. Shim systemctl zostawił je z plikiem down i wpisem w liście; tu (runit core-service,
# sourcowany przez /bin/sh przed startem usług) zdejmujemy down i czyścimy listę.
_omp_list=/var/lib/omarchy-port/start-at-boot
if [ -f "$_omp_list" ]; then
  while read -r _omp_sv; do
    [ -n "$_omp_sv" ] && [ -d "/etc/sv/$_omp_sv" ] && rm -f "/etc/sv/$_omp_sv/down"
  done <"$_omp_list"
  rm -f "$_omp_list"
fi
unset _omp_list _omp_sv
