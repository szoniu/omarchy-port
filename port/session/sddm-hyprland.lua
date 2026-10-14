-- omarchy-port: config Hyprlanda dla greetera SDDM = upstreamowy z Omarchy + bez okna
-- „Hyprland updated” (hyprland-update-screen). Greeter nie ma no_update_news, więc po każdej
-- aktualizacji Hyprlanda okno wyskakuje NAD polem hasła i zabiera klawiaturę (omarchy-port#2).
-- Sesja użytkownika ma to samo ustawienie w default/hypr/envs.lua Omarchy.
dofile("/usr/share/sddm/hyprland.lua")
hl.config({
  ecosystem = {
    no_update_news = true,
  },
})
