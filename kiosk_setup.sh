#!/bin/bash
set -e

# =========================
# Spinner megjelenítése
# =========================
spinner() {
  local pid=$1
  local message=$2
  local delay=0.1
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

  tput civis 2>/dev/null || true
  local i=0
  while [ -d "/proc/$pid" ]; do
    local frame=${frames[$i]}
    printf "\r\e[35m%s\e[0m %s" "$frame" "$message"
    i=$(((i + 1) % ${#frames[@]}))
    sleep "$delay"
  done
  printf "\r\e[32m✔\e[0m %s\n" "$message"
  tput cnorm 2>/dev/null || true
}

# =========================
# Ellenőrzés: ne fusson rootként
# =========================
if [ "$(id -u)" -eq 0 ]; then
  echo "Ezt a scriptet nem szabad rootként futtatni. Kérlek normál felhasználóként futtasd, sudo jogosultsággal."
  exit 1
fi

# Aktuális felhasználó és home könyvtár
CURRENT_USER="$(whoami)"
HOME_DIR="$(eval echo "~$CURRENT_USER")"

# Boot konfigurációs fájl útvonalának meghatározása (distro/kiadás függő)
if [ -f "/boot/firmware/config.txt" ]; then
  BOOT_CONFIG="/boot/firmware/config.txt"
  BOOT_CMDLINE="/boot/firmware/cmdline.txt"
else
  BOOT_CONFIG="/boot/config.txt"
  BOOT_CMDLINE="/boot/cmdline.txt"
fi

# =========================
# Függvény igen/nem kérdéshez alapértelmezett értékkel
# =========================
ask_user() {
  local prompt="$1"
  local default="$2"
  local default_text=""

  if [ "$default" = "y" ]; then
    default_text=" [alapértelmezett: igen]"
  elif [ "$default" = "n" ]; then
    default_text=" [alapértelmezett: nem]"
  fi

  while true; do
    read -p "$prompt$default_text (y/n): " yn
    yn="${yn:-$default}"
    case $yn in
      [Yy]* ) return 0;;
      [Nn]* ) return 1;;
      * ) echo "Kérlek igen (y) vagy nem (n) választ adj.";;
    esac
  done
}

# =========================
# KIOSKPARANCS blokkok kezelése
# =========================
KIOSK_BEGIN="#KIOSKPARANCS_BEGIN"
KIOSK_END="#KIOSKPARANCS_END"

is_root_file() {
  local file="$1"
  case "$file" in
    /boot/*|/boot/firmware/*|/etc/*|/usr/*|/var/*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_parent_dir() {
  local f="$1"
  local d
  d="$(dirname "$f")"

  if is_root_file "$f"; then
    sudo mkdir -p "$d"
  else
    mkdir -p "$d"
  fi
}

remove_kiosk_block() {
  local file="$1"
  [ -f "$file" ] || return 0

  if is_root_file "$file"; then
    sudo sed -i "/^${KIOSK_BEGIN}\$/,/^${KIOSK_END}\$/d" "$file"
  else
    sed -i "/^${KIOSK_BEGIN}\$/,/^${KIOSK_END}\$/d" "$file"
  fi
}

write_kiosk_block() {
  local file="$1"
  local content="$2"

  ensure_parent_dir "$file"

  # fájl létezzen (root esetén sudo-val)
  if [ ! -f "$file" ]; then
    if is_root_file "$file"; then
      sudo touch "$file"
    else
      touch "$file"
    fi
  fi

  remove_kiosk_block "$file"

  if is_root_file "$file"; then
    {
      echo "$KIOSK_BEGIN"
      printf "%b\n" "$content"
      echo "$KIOSK_END"
    } | sudo tee -a "$file" > /dev/null
  else
    {
      echo "$KIOSK_BEGIN"
      printf "%b\n" "$content"
      echo "$KIOSK_END"
    } >> "$file"
  fi
}

# =========================
# cmdline.txt paraméter-szintű kezelés
# (a cmdline.txt egyetlen sor, paramétereket cserélünk benne)
# =========================
read_cmdline_one_line() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  tr -d '\r' < "$file" | head -n 1
}

write_cmdline_one_line() {
  local file="$1"
  local line="$2"
  printf "%s\n" "$line" | sudo tee "$file" > /dev/null
}

cmdline_remove_key() {
  local line="$1"
  local key="$2"
  echo "$line" \
    | sed -E "s/(^|[[:space:]])${key}=[^[:space:]]+//g" \
    | sed -E 's/[[:space:]]+/ /g' \
    | sed -E 's/^ //; s/ $//'
}

cmdline_set_key_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  local line
  line="$(read_cmdline_one_line "$file")"
  line="$(cmdline_remove_key "$line" "$key")"

  if [ -n "$line" ]; then
    line="${line} ${key}=${value}"
  else
    line="${key}=${value}"
  fi

  write_cmdline_one_line "$file" "$line"
}

cmdline_ensure_flag() {
  local file="$1"
  local flag="$2"

  local line
  line="$(read_cmdline_one_line "$file")"

  if echo " $line " | grep -qE "[[:space:]]${flag}[[:space:]]"; then
    return 0
  fi

  if [ -n "$line" ]; then
    line="${line} ${flag}"
  else
    line="${flag}"
  fi

  write_cmdline_one_line "$file" "$line"
}

# =========================
# Memóriában épített beállítások (a végén egyben írjuk ki)
# =========================
LABWC_AUTOSTART_FILE="$HOME_DIR/.config/labwc/autostart"
AUTOSTART_NEEDS_UPDATE="n"
AUTOSTART_BLOCK=""

CONFIG_NEEDS_UPDATE="n"
CONFIG_BLOCK=""

CMDLINE_NEEDS_SPLASH="n"
CMDLINE_NEEDS_CONSOLE_TTY3="n"
CMDLINE_VIDEO_VALUE=""   # pl. HDMI-A-1:1920x1080@60

# =========================
# 1) Csomaglista frissítése?
# =========================
echo
if ask_user "Szeretnéd frissíteni a csomaglistát?" "y"; then
  echo -e "\e[90mCsomaglista frissítése folyamatban, kérlek várj...\e[0m"
  sudo apt update > /dev/null 2>&1 &
  spinner $! "Csomaglista frissítése..."
fi

# =========================
# 2) Telepített csomagok frissítése?
# =========================
echo
if ask_user "Szeretnéd frissíteni a telepített csomagokat?" "y"; then
  echo -e "\e[90mTelepített csomagok frissítése folyamatban (ez eltarthat egy ideig), kérlek várj...\e[0m"
  sudo apt upgrade -y > /dev/null 2>&1 &
  spinner $! "Telepített csomagok frissítése..."
fi

# =========================
# 3) Wayland / labwc telepítése?
# =========================
echo
if ask_user "Szeretnéd telepíteni a Wayland és labwc csomagokat?" "y"; then
  echo -e "\e[90mWayland csomagok telepítése folyamatban, kérlek várj...\e[0m"
  sudo apt install --no-install-recommends -y labwc wlr-randr seatd > /dev/null 2>&1 &
  spinner $! "Wayland csomagok telepítése..."

  sudo systemctl enable --now seatd > /dev/null 2>&1 || true

  # Ha létezik seat csoport, hozzáadjuk (distrofüggő)
  if getent group seat > /dev/null 2>&1; then
    if id -nG "$CURRENT_USER" | tr ' ' '\n' | grep -qx seat; then
      echo -e "\e[33mA '$CURRENT_USER' már tagja a 'seat' csoportnak.\e[0m"
    else
      sudo usermod -aG seat "$CURRENT_USER"
      echo -e "\e[33mA '$CURRENT_USER' hozzá lett adva a 'seat' csoporthoz. A változás reboot után lép életbe.\e[0m"
    fi
  fi
fi

# =========================
# 4) Chromium telepítése?
# =========================
echo
if ask_user "Szeretnéd telepíteni a Chromium böngészőt?" "y"; then
  CHROMIUM_PKG=""
  if apt-cache show chromium >/dev/null 2>&1; then
    CHROMIUM_PKG="chromium"
  elif apt-cache show chromium-browser >/dev/null 2>&1; then
    CHROMIUM_PKG="chromium-browser"
  fi

  if [ -z "$CHROMIUM_PKG" ]; then
    echo -e "\e[33mNem található Chromium csomag az APT-ben. Lehet, hogy tároló kell, vagy kézi telepítés.\e[0m"
  else
    echo -e "\e[90mChromium telepítése folyamatban (ez eltarthat egy ideig), kérlek várj...\e[0m"
    sudo apt install --no-install-recommends -y "$CHROMIUM_PKG" > /dev/null 2>&1 &
    spinner $! "Chromium telepítése..."
  fi
fi

# =========================
# 5) greetd telepítése és beállítása? (LightDM <-> greetd váltó)
# =========================
echo
if ask_user "Szeretnéd telepíteni és használni a greetd-t (kioszk labwc autologin)?" "n"; then
  # --- Y ág: greetd bekapcs, lightdm kikapcs ---
  echo -e "\e[90mLightDM leállítása és letiltása (ha fut/telepítve van)...\e[0m"
  sudo systemctl disable --now lightdm > /dev/null 2>&1 || true

  echo -e "\e[90mgreetd telepítése folyamatban...\e[0m"
  sudo apt install -y greetd > /dev/null 2>&1 &
  spinner $! "greetd telepítése..."

  echo -e "\e[90m/etc/greetd/config.toml létrehozása vagy felülírása...\e[0m"
  sudo mkdir -p /etc/greetd
  sudo bash -c "cat <<EOL > /etc/greetd/config.toml
[terminal]
vt = 7
[default_session]
command = \"/usr/bin/labwc\"
user = \"$CURRENT_USER\"
EOL"

  echo -e "\e[32m✔\e[0m /etc/greetd/config.toml frissítve!"

  echo -e "\e[90mgreetd szolgáltatás engedélyezése és indítása...\e[0m"
  sudo systemctl enable --now greetd > /dev/null 2>&1 &
  spinner $! "greetd enable --now..."

  echo -e "\e[90mGrafikus target beállítása alapértelmezettként...\e[0m"
  sudo systemctl set-default graphical.target > /dev/null 2>&1 &
  spinner $! "Graphical target beállítása..."

else
  # --- N ág: greetd kikapcs, lightdm vissza ---
  echo -e "\e[90mgreetd leállítása és letiltása (ha telepítve van)...\e[0m"
  sudo systemctl disable --now greetd > /dev/null 2>&1 || true

  echo -e "\e[90mLightDM engedélyezése és indítása (ha telepítve van)...\e[0m"
  sudo systemctl enable --now lightdm > /dev/null 2>&1 || true

  echo -e "\e[90mGrafikus target beállítása alapértelmezettként...\e[0m"
  sudo systemctl set-default graphical.target > /dev/null 2>&1 || true
  echo -e "\e[32m✔\e[0m LightDM mód visszaállítva (ahol elérhető)."

  # --- EXTRA: greetd csomag törlése N esetén (opcionális) ---
  if dpkg -s greetd >/dev/null 2>&1; then
    echo
    if ask_user "Szeretnéd eltávolítani a greetd csomagot is (purge)?" "y"; then
      echo -e "\e[90mgreetd eltávolítása (purge)...\e[0m"
      sudo apt purge -y greetd > /dev/null 2>&1 &
      spinner $! "greetd purge..."

      echo -e "\e[90mFelesleges csomagok takarítása (autoremove)...\e[0m"
      sudo apt autoremove -y > /dev/null 2>&1 &
      spinner $! "autoremove..."

      echo -e "\e[32m✔\e[0m greetd eltávolítva."
    fi
  fi
fi

# =========================
# 6) labwc autostart: Chromium indítás (KIOSKPARANCS blokkba, memóriából)
# =========================
echo
if ask_user "Szeretnél Chromium autostartot létrehozni labwc-hez?" "y"; then
  read -p "Add meg a Chromiumban megnyitandó URL-t [alapértelmezett: https://planka.athq.cc]: " USER_URL
  USER_URL="${USER_URL:-https://planka.athq.cc}"

  echo
  INCOGNITO_FLAG=""
  if ask_user "Induljon a böngésző inkognitó módban?" "n"; then
    INCOGNITO_FLAG="--incognito "
  fi

  echo
  USE_NET_WAIT="n"
  if ask_user "Várjon hálózati kapcsolatra a Chromium indítása előtt?" "n"; then
    USE_NET_WAIT="y"
  fi

  PING_HOST="8.8.8.8"
  MAX_WAIT="30"
  if [ "$USE_NET_WAIT" = "y" ]; then
    read -p "Add meg a pingelendő hostot a hálózati ellenőrzéshez [alapértelmezett: 8.8.8.8]: " PING_HOST_IN
    PING_HOST="${PING_HOST_IN:-8.8.8.8}"
    read -p "Add meg a maximális várakozási időt másodpercben [alapértelmezett: 30]: " MAX_WAIT_IN
    MAX_WAIT="${MAX_WAIT_IN:-30}"
  fi

  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
  if [ -z "$CHROMIUM_BIN" ]; then
    if [ -x "/usr/bin/chromium" ]; then
      CHROMIUM_BIN="/usr/bin/chromium"
    elif [ -x "/usr/bin/chromium-browser" ]; then
      CHROMIUM_BIN="/usr/bin/chromium-browser"
    else
      CHROMIUM_BIN="/usr/bin/chromium"
      echo -e "\e[33mFigyelmeztetés: nem található Chromium bináris. Autostartban ez lesz: $CHROMIUM_BIN (ha kell, később javítsd).\e[0m"
    fi
  fi

  # Extra kapcsolók: kevesebb felugró (első futás / fordítás)
  CHROME_FLAGS="${INCOGNITO_FLAG}--autoplay-policy=no-user-gesture-required --enable-features=UseOzonePlatform --ozone-platform=wayland --no-first-run --simulate-outdated-no-au --disable-features=Translate --kiosk \"${USER_URL}\""

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  if [ "$USE_NET_WAIT" = "y" ]; then
    AUTOSTART_BLOCK+="# Chromium indítása kioszk módban (hálózatra várással)\n"
    AUTOSTART_BLOCK+="(\n"
    AUTOSTART_BLOCK+="  NET_OK=0\n"
    AUTOSTART_BLOCK+="  for i in \$(seq 1 ${MAX_WAIT}); do\n"
    AUTOSTART_BLOCK+="    if ping -c 1 -W 2 ${PING_HOST} > /dev/null 2>&1; then\n"
    AUTOSTART_BLOCK+="      NET_OK=1\n"
    AUTOSTART_BLOCK+="      sleep 2\n"
    AUTOSTART_BLOCK+="      break\n"
    AUTOSTART_BLOCK+="    fi\n"
    AUTOSTART_BLOCK+="    sleep 1\n"
    AUTOSTART_BLOCK+="  done\n"
    AUTOSTART_BLOCK+="\n"
    AUTOSTART_BLOCK+="  if [ \"\$NET_OK\" -ne 1 ]; then\n"
    AUTOSTART_BLOCK+="    echo \"[KIOSK] FIGYELEM: nincs hálózat ${MAX_WAIT} mp után sem, a Chromium így is indul.\" >&2\n"
    AUTOSTART_BLOCK+="    sleep 2\n"
    AUTOSTART_BLOCK+="  fi\n"
    AUTOSTART_BLOCK+="\n"
    AUTOSTART_BLOCK+="  ${CHROMIUM_BIN} ${CHROME_FLAGS}\n"
    AUTOSTART_BLOCK+=") &\n"
  else
    AUTOSTART_BLOCK+="# Chromium indítása kioszk módban\n"
    AUTOSTART_BLOCK+="${CHROMIUM_BIN} ${CHROME_FLAGS} &\n"
  fi

  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 7) Egérkurzor elrejtése (wtype) - autostart blokkba
# =========================
echo
if ask_user "Szeretnéd elrejteni az egérkurzort kioszk módban?" "y"; then
  if ! command -v wtype > /dev/null 2>&1; then
    echo -e "\e[90mwtype telepítése folyamatban, kérlek várj...\e[0m"
    sudo apt install -y wtype > /dev/null 2>&1 &
    spinner $! "wtype telepítése..."
  fi

  LABWC_CONFIG_DIR="$HOME_DIR/.config/labwc"
  mkdir -p "$LABWC_CONFIG_DIR"
  RC_XML="$LABWC_CONFIG_DIR/rc.xml"

  if [ -f "$RC_XML" ]; then
    if grep -q "HideCursor" "$RC_XML" 2>/dev/null; then
      echo -e "\e[33mAz rc.xml már tartalmaz HideCursor beállítást. Nem módosítom.\e[0m"
    else
      echo -e "\e[90mHideCursor billentyűparancs hozzáadása a meglévő rc.xml-hez...\e[0m"
      if grep -q "</keyboard>" "$RC_XML"; then
        sed -i 's|</keyboard>|  <keybind key="W-h">\n    <action name="HideCursor"/>\n    <action name="WarpCursor" to="output" x="1" y="1"/>\n  </keybind>\n</keyboard>|' "$RC_XML"
      else
        echo -e "\e[33mNem található </keyboard> tag az rc.xml-ben. Kérlek add hozzá kézzel a HideCursor billentyűparancsot.\e[0m"
      fi
    fi
  else
    echo -e "\e[90mrc.xml létrehozása HideCursor beállítással...\e[0m"
    cat > "$RC_XML" << 'EOL'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <keybind key="W-h">
      <action name="HideCursor"/>
      <action name="WarpCursor" to="output" x="1" y="1"/>
    </keybind>
  </keyboard>
</labwc_config>
EOL
    echo -e "\e[32m✔\e[0m rc.xml sikeresen létrehozva!"
  fi

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Kurzor elrejtése indításkor (Win+H billentyű szimulálása)\n"
  AUTOSTART_BLOCK+="(sleep 5 && wtype -M logo -k h -m logo) &\n"
  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 8) Splash képernyő telepítése?
# - config.txt: KIOSKPARANCS blokkba memóriából
# - cmdline.txt: paraméter szinten beállítjuk a végén
# =========================
echo
if ask_user "Szeretnéd telepíteni a splash képernyőt?" "y"; then
  echo -e "\e[90mSplash képernyő és témák telepítése folyamatban (ez eltarthat), kérlek várj...\e[0m"
  sudo apt-get install -y plymouth plymouth-themes pix-plym-splash > /dev/null 2>&1 &
  spinner $! "Splash telepítése..."

  if [ ! -e /usr/share/plymouth/themes/pix/pix.script ]; then
    echo -e "\e[33mFigyelmeztetés: a pix téma nem található. Splash lehet nem működik megfelelően.\e[0m"
  else
    echo -e "\e[90mSplash téma beállítása pix-re...\e[0m"
    sudo plymouth-set-default-theme pix > /dev/null 2>&1 || true

    echo -e "\e[90mEgyedi splash logó letöltése...\e[0m"
    SPLASH_URL="https://raw.githubusercontent.com/MISIKEX/rpi-kiosk/main/_assets/splashscreens/splash.png"
    SPLASH_PATH="/usr/share/plymouth/themes/pix/splash.png"

    if sudo wget -q "$SPLASH_URL" -O "$SPLASH_PATH"; then
      echo -e "\e[32m✔\e[0m Egyedi splash logó telepítve."
    else
      echo -e "\e[33mFigyelmeztetés: nem sikerült letölteni az egyedi splash logót. Marad az alapértelmezett.\e[0m"
    fi

    sudo update-initramfs -u > /dev/null 2>&1 &
    spinner $! "initramfs frissítése..."
  fi

  CONFIG_NEEDS_UPDATE="y"
  if [ -z "$CONFIG_BLOCK" ]; then
    CONFIG_BLOCK+="# Raspberry Pi kioszk beállítások\n"
    CONFIG_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    CONFIG_BLOCK+="\n"
  fi
  CONFIG_BLOCK+="# Splash képernyő engedélyezése / beállítása\n"
  CONFIG_BLOCK+="disable_splash=1\n"
  CONFIG_BLOCK+="\n"

  CMDLINE_NEEDS_SPLASH="y"
  CMDLINE_NEEDS_CONSOLE_TTY3="y"
fi

# =========================
# 9) Képernyőfelbontás beállítása?
# - cmdline.txt: video= paraméter érték (a végén cseréljük)
# - autostart: wlr-randr sor blokkba
# =========================
echo
if ask_user "Szeretnéd beállítani a képernyőfelbontást (cmdline.txt + labwc autostart)?" "y"; then
  if ! command -v edid-decode > /dev/null 2>&1; then
    echo -e "\e[90mSzükséges eszköz (edid-decode) telepítése, kérlek várj...\e[0m"
    sudo apt install -y edid-decode > /dev/null 2>&1 &
    spinner $! "edid-decode telepítése..."
  fi

  EDID_PATH=""
  if [ -r /sys/class/drm/card1-HDMI-A-1/edid ]; then
    EDID_PATH="/sys/class/drm/card1-HDMI-A-1/edid"
  elif [ -r /sys/class/drm/card0-HDMI-A-1/edid ]; then
    EDID_PATH="/sys/class/drm/card0-HDMI-A-1/edid"
  fi

  available_resolutions=()
  if [ -n "$EDID_PATH" ]; then
    edid_output="$(sudo cat "$EDID_PATH" | edid-decode 2>/dev/null || true)"
    while IFS= read -r line; do
      if [[ "$line" =~ ([0-9]+)x([0-9]+)[[:space:]]+([0-9]+\.[0-9]+|[0-9]+)\ Hz ]]; then
        resolution="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
        frequency="${BASH_REMATCH[3]}"
        available_resolutions+=("${resolution}@${frequency}")
      fi
    done <<< "$edid_output"
  fi

  if [ ${#available_resolutions[@]} -eq 0 ]; then
    echo -e "\e[33mNem találtam EDID felbontásokat. Alapértelmezett listát használok.\e[0m"
    available_resolutions=("1920x1080@60" "1280x720@60" "1024x768@60" "1600x900@60" "1366x768@60")
  fi

  echo -e "\e[94mKérlek válassz felbontást (számot írj):\e[0m"
  select RESOLUTION in "${available_resolutions[@]}"; do
    if [[ -n "$RESOLUTION" ]]; then
      echo -e "\e[32mKiválasztva: $RESOLUTION\e[0m"
      break
    else
      echo -e "\e[33mÉrvénytelen választás, próbáld újra.\e[0m"
    fi
  done

  CMDLINE_VIDEO_VALUE="HDMI-A-1:${RESOLUTION}"

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Képernyőfelbontás beállítása\n"
  AUTOSTART_BLOCK+="wlr-randr --output HDMI-A-1 --mode ${RESOLUTION}\n"
  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 10) Képernyő elforgatása?
# - autostart: wlr-randr transform sor blokkba
# =========================
echo
if ask_user "Szeretnéd beállítani a képernyő elforgatását?" "n"; then
  echo -e "\e[94mKérlek válassz tájolást:\e[0m"
  orientations=("normal (0°)" "90° jobbra" "180°" "270° jobbra")
  transform_values=("normal" "90" "180" "270")

  select orientation in "${orientations[@]}"; do
    if [[ -n "$orientation" ]]; then
      idx=$((REPLY - 1))
      TRANSFORM="${transform_values[$idx]}"
      echo -e "\e[32mKiválasztva: $orientation\e[0m"
      break
    else
      echo -e "\e[33mÉrvénytelen választás, próbáld újra.\e[0m"
    fi
  done

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Képernyő elforgatás beállítása\n"
  AUTOSTART_BLOCK+="wlr-randr --output HDMI-A-1 --transform ${TRANSFORM}\n"
  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 11) Hangkimenet HDMI-re kényszerítése?
# - config.txt: KIOSKPARANCS blokkba memóriából
# =========================
echo
if ask_user "Szeretnéd a hangkimenetet HDMI-re kényszeríteni?" "y"; then
  CONFIG_NEEDS_UPDATE="y"
  if [ -z "$CONFIG_BLOCK" ]; then
    CONFIG_BLOCK+="# Raspberry Pi kioszk beállítások\n"
    CONFIG_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    CONFIG_BLOCK+="\n"
  fi
  CONFIG_BLOCK+="# Hang: HDMI kimenet kényszerítése\n"
  CONFIG_BLOCK+="dtparam=audio=off\n"
  CONFIG_BLOCK+="\n"
fi

# =========================
# 12) TV távirányító (HDMI-CEC) támogatás engedélyezése?
# =========================
echo
if ask_user "Szeretnéd engedélyezni a TV távirányítót HDMI-CEC-en keresztül?" "n"; then
  echo -e "\e[90mCEC segédprogramok telepítése folyamatban, kérlek várj...\e[0m"
  sudo apt-get install -y ir-keytable v4l-utils > /dev/null 2>&1 &
  spinner $! "CEC segédprogramok telepítése..."

  echo -e "\e[90mEgyedi CEC billentyűtérkép létrehozása...\e[0m"
  sudo mkdir -p /etc/rc_keymaps

  sudo bash -c "cat > /etc/rc_keymaps/custom-cec.toml" << 'EOL'
[[protocols]]
name = "custom_cec"
protocol = "cec"
[protocols.scancodes]
0x00 = "KEY_ENTER"
0x01 = "KEY_UP"
0x02 = "KEY_DOWN"
0x03 = "KEY_LEFT"
0x04 = "KEY_RIGHT"
0x09 = "KEY_EXIT"
0x0d = "KEY_BACK"
0x44 = "KEY_PLAYPAUSE"
0x45 = "KEY_STOPCD"
0x46 = "KEY_PAUSECD"
EOL

  echo -e "\e[32m✔\e[0m Egyedi CEC billentyűtérkép létrehozva!"

  echo -e "\e[90mCEC beállító wrapper script létrehozása...\e[0m"
  sudo bash -c "cat > /usr/local/bin/cec-setup.sh" << 'EOL'
#!/bin/bash
set -e

# 1) CEC eszköz detektálás: első létező /dev/cec*
CEC_DEV=""
for dev in /dev/cec*; do
  if [ -e "$dev" ]; then
    CEC_DEV="$dev"
    break
  fi
done

if [ -z "$CEC_DEV" ]; then
  echo "HIBA: Nem található /dev/cec* eszköz."
  exit 1
fi

# 2) rc eszköz detektálás: első ir-keytable által listázott rcX (rc0, rc1...)
RC_DEV=""
if command -v ir-keytable >/dev/null 2>&1; then
  RC_DEV=$(ir-keytable -l 2>/dev/null | grep -o 'rc[0-9]\+' | head -n 1 || true)
fi

if [ -z "$RC_DEV" ]; then
  RC_DEV="rc0"
fi

# 3) CEC beállítások
/usr/bin/cec-ctl -d "$CEC_DEV" --playback
sleep 2
/usr/bin/cec-ctl -d "$CEC_DEV" --active-source phys-addr=1.0.0.0
sleep 1

# 4) Keymap betöltése
/usr/bin/ir-keytable -c -s "$RC_DEV" -w /etc/rc_keymaps/custom-cec.toml

exit 0
EOL

  sudo chmod +x /usr/local/bin/cec-setup.sh
  echo -e "\e[32m✔\e[0m CEC wrapper script létrehozva: /usr/local/bin/cec-setup.sh"

  echo -e "\e[90mCEC systemd szolgáltatás létrehozása...\e[0m"
  sudo bash -c "cat > /etc/systemd/system/cec-setup.service" << 'EOL'
[Unit]
Description=CEC Remote Control Setup
After=multi-user.target
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

  sudo systemctl daemon-reload > /dev/null 2>&1

  echo -e "\e[90mCEC szolgáltatás engedélyezése...\e[0m"
  sudo systemctl enable cec-setup.service > /dev/null 2>&1 &
  spinner $! "CEC szolgáltatás engedélyezése..."

  echo -e "\e[32m✔\e[0m HDMI-CEC távirányító támogatás beállítva!"
  echo -e "\e[90mMegjegyzés: a TV-n engedélyezd a HDMI-CEC-et (SimpLink/Anynet+/Bravia Sync).\e[0m"
fi

# =========================
# VÉGÉN: fájlmódosítások EGYBEN
# =========================

# 1) labwc autostart KIOSKPARANCS blokk kiírása (ha kellett)
if [ "$AUTOSTART_NEEDS_UPDATE" = "y" ]; then
  write_kiosk_block "$LABWC_AUTOSTART_FILE" "$AUTOSTART_BLOCK"
  echo -e "\e[32m✔\e[0m labwc autostart frissítve (KIOSKPARANCS blokk): $LABWC_AUTOSTART_FILE"
fi

# 2) config.txt KIOSKPARANCS blokk kiírása (ha kellett)
if [ "$CONFIG_NEEDS_UPDATE" = "y" ]; then
  write_kiosk_block "$BOOT_CONFIG" "$CONFIG_BLOCK"
  echo -e "\e[32m✔\e[0m boot config frissítve (KIOSKPARANCS blokk): $BOOT_CONFIG"
fi

# 3) cmdline.txt paraméter-szintű módosítások (ha kellett)
if [ "$CMDLINE_NEEDS_SPLASH" = "y" ] || [ "$CMDLINE_NEEDS_CONSOLE_TTY3" = "y" ] || [ -n "$CMDLINE_VIDEO_VALUE" ]; then
  if [ -f "$BOOT_CMDLINE" ]; then
    if [ "$CMDLINE_NEEDS_SPLASH" = "y" ]; then
      cmdline_ensure_flag "$BOOT_CMDLINE" "quiet"
      cmdline_ensure_flag "$BOOT_CMDLINE" "splash"
      cmdline_ensure_flag "$BOOT_CMDLINE" "plymouth.ignore-serial-consoles"
    fi
    if [ "$CMDLINE_NEEDS_CONSOLE_TTY3" = "y" ]; then
      cmdline_set_key_value "$BOOT_CMDLINE" "console" "tty3"
    fi
    if [ -n "$CMDLINE_VIDEO_VALUE" ]; then
      cmdline_set_key_value "$BOOT_CMDLINE" "video" "$CMDLINE_VIDEO_VALUE"
    fi
    echo -e "\e[32m✔\e[0m cmdline.txt frissítve (paraméter-szinten): $BOOT_CMDLINE"
  else
    echo -e "\e[33mFigyelmeztetés: $BOOT_CMDLINE nem található, cmdline módosítás kihagyva.\e[0m"
  fi
fi

# =========================
# apt gyorsítótárak takarítása
# =========================
echo -e "\e[90mAPT gyorsítótárak takarítása, kérlek várj...\e[0m"
sudo apt clean > /dev/null 2>&1 &
spinner $! "APT gyorsítótárak takarítása..."

# =========================
# Befejezés + újraindítás felajánlása
# =========================
echo -e "\e[32m✔\e[0m \e[32mA beállítás sikeresen befejeződött!\e[0m"
echo
if ask_user "Szeretnéd most újraindítani a rendszert?" "y"; then
  echo -e "\e[90mRendszer újraindítása...\e[0m"
  sudo reboot
else
  echo -e "\e[33mNe felejtsd el manuálisan újraindítani a rendszert, hogy minden változás érvénybe lépjen.\e[0m"
fi