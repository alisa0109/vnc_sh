#!/usr/bin/env bash
# =============================================================================
#  setup-vnc.sh — інтерактивне встановлення VNC для Debian / Ubuntu / Kali
#
#  Режими:
#    1) Окремий віртуальний робочий стіл (TigerVNC, порт 5900+N)  — рекомендовано
#    2) Доступ до існуючого екрана (x11vnc, порт 5900)             — як "віддалений монітор"
#
#  Також: systemd-автозапуск, ufw, SSH-тунель (безпечно), файли "підключення в 1 клік"
#  Запуск:  sudo bash setup-vnc.sh
# =============================================================================
set -euo pipefail

# ---------- кольори ----------
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
info()  { echo "${B}[i]${N} $*"; }
ok()    { echo "${G}[✓]${N} $*"; }
warn()  { echo "${Y}[!]${N} $*"; }
die()   { echo "${R}[✗]${N} $*" >&2; exit 1; }

# ---------- допоміжні функції запитань ----------
ask() {  # ask "Питання" "значення за замовчуванням" -> $REPLY_VAL
  local prompt="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then read -r -p "$prompt [$def]: " ans; REPLY_VAL="${ans:-$def}"
  else read -r -p "$prompt: " ans; REPLY_VAL="$ans"; fi
}
ask_yn() {  # ask_yn "Питання" y|n -> return 0 якщо так
  local prompt="$1" def="${2:-y}" ans hint
  [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
  read -r -p "$prompt [$hint]: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[YyТтНн]|^[Yy]es$ ]] && [[ ! "$ans" =~ ^[Nn] ]]
}
ask_secret() {
  local p1 p2
  while true; do
    read -r -s -p "$1: " p1; echo
    read -r -s -p "Повторіть пароль: " p2; echo
    [[ -z "$p1" ]] && { warn "Пароль не може бути порожнім."; continue; }
    [[ "$p1" == "$p2" ]] || { warn "Паролі не збігаються."; continue; }
    REPLY_VAL="$p1"; return
  done
}

# ---------- перевірки ----------
[[ $EUID -eq 0 ]] || die "Запустіть від root:  sudo bash $0"
command -v apt-get >/dev/null || die "Потрібна система на базі apt (Debian/Ubuntu/Kali)."

OS_ID="unknown"; OS_NAME="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release; OS_ID="${ID:-unknown}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
fi
case "$OS_ID" in
  debian|ubuntu|kali|linuxmint|pop|raspbian) ;;
  *) warn "Система '$OS_NAME' офіційно не тестувалась, але продовжую (apt-based)." ;;
esac

clear
cat <<EOF
${B}==============================================${N}
   Майстер налаштування VNC
   Система: $OS_NAME
${B}==============================================${N}
EOF

# ---------- головне меню ----------
echo
echo "Що робимо?"
echo "  1) Встановити та налаштувати VNC"
echo "  2) Видалити налаштований VNC-сервіс"
ask "Ваш вибір" "1"; ACTION="$REPLY_VAL"

# ---------- видалення ----------
if [[ "$ACTION" == "2" ]]; then
  mapfile -t UNITS < <(ls /etc/systemd/system/ 2>/dev/null | grep -E '^(vnc-|x11vnc-custom)' || true)
  [[ ${#UNITS[@]} -gt 0 ]] || die "Сервісів, створених цим скриптом, не знайдено."
  info "Знайдені сервіси: ${UNITS[*]}"
  if ask_yn "Зупинити й видалити їх?" y; then
    for u in "${UNITS[@]}"; do
      systemctl disable --now "$u" 2>/dev/null || true
      rm -f "/etc/systemd/system/$u"
    done
    systemctl daemon-reload
    ok "Сервіси видалено. Пакети та ~/.vnc залишено (видаліть вручну за потреби)."
  fi
  exit 0
fi

# ---------- вибір режиму ----------
echo
echo "Який режим потрібен?"
echo "  1) Окремий віртуальний робочий стіл (TigerVNC) — рекомендовано для серверів/Kali"
echo "  2) Показати поточний екран (x11vnc) — потрібна графічна сесія на :0, Wayland не підходить"
ask "Ваш вибір" "1"; MODE="$REPLY_VAL"
[[ "$MODE" =~ ^[12]$ ]] || die "Невірний вибір."

# ---------- користувач ----------
DEF_USER="${SUDO_USER:-root}"
ask "Від імені якого користувача запускати VNC" "$DEF_USER"; VUSER="$REPLY_VAL"
if ! id "$VUSER" &>/dev/null; then
  if ask_yn "Користувача '$VUSER' не існує. Створити?" y; then
    adduser --gecos "" "$VUSER"
  else die "Користувач не існує."; fi
fi
HOME_DIR="$(getent passwd "$VUSER" | cut -d: -f6)"

# ---------- параметри ----------
DISPLAY_NUM=1; RES="1920x1080"; DE="xfce"
if [[ "$MODE" == "1" ]]; then
  ask "Номер дисплея (порт буде 5900+N)" "1"; DISPLAY_NUM="$REPLY_VAL"
  [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]] || die "Номер дисплея має бути числом."
  ask "Роздільна здатність" "1920x1080"; RES="$REPLY_VAL"
  echo
  echo "Графічне середовище:"
  echo "  1) XFCE  (легке, рекомендовано)"
  echo "  2) MATE"
  echo "  3) Вже встановлене — не ставити нове (скажіть команду запуску далі)"
  ask "Ваш вибір" "1"
  case "$REPLY_VAL" in
    1) DE="xfce" ;;
    2) DE="mate" ;;
    3) DE="custom"; ask "Команда запуску сесії (напр. startxfce4, mate-session)" "startxfce4"; DE_CMD="$REPLY_VAL" ;;
    *) die "Невірний вибір." ;;
  esac
  PORT=$((5900 + DISPLAY_NUM))
else
  PORT=5900
  ask "Порт x11vnc" "5900"; PORT="$REPLY_VAL"
  if [[ -n "${XDG_SESSION_TYPE:-}" && "${XDG_SESSION_TYPE}" == "wayland" ]]; then
    warn "Виявлено Wayland — x11vnc не працюватиме. Перейдіть на X11-сесію при вході."
  fi
fi

ask_secret "Придумайте пароль для VNC (VNC враховує лише перші 8 символів)"; VNC_PASS="$REPLY_VAL"
[[ ${#VNC_PASS} -gt 8 ]] && warn "Пароль довший за 8 символів — буде обрізаний VNC-протоколом."

echo
echo "Безпека підключення:"
echo "  1) Тільки через SSH-тунель (VNC слухає лише localhost) — безпечно, рекомендовано"
echo "  2) Напряму по мережі (трафік VNC НЕ шифрується)"
ask "Ваш вибір" "1"; SEC="$REPLY_VAL"
LOCAL_ONLY="yes"; [[ "$SEC" == "2" ]] && LOCAL_ONLY="no"

DEF_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ask "IP або домен цього сервера для файлів підключення" "${DEF_IP:-127.0.0.1}"; SRV_ADDR="$REPLY_VAL"
SSH_PORT="22"
if [[ "$LOCAL_ONLY" == "yes" ]]; then
  ask "SSH-порт сервера" "22"; SSH_PORT="$REPLY_VAL"
fi

USE_UFW="n"
if command -v ufw >/dev/null; then
  if ask_yn "Налаштувати ufw (брандмауер)?" y; then USE_UFW="y"; fi
fi
ALLOW_FROM=""
if [[ "$USE_UFW" == "y" && "$LOCAL_ONLY" == "no" ]]; then
  ask "Дозволити доступ лише з IP (порожньо = з будь-якого)" ""; ALLOW_FROM="$REPLY_VAL"
fi

AUTOSTART=y
ask_yn "Запускати VNC автоматично при старті системи?" y || AUTOSTART=n

# ---------- підсумок ----------
echo
echo "${B}---------- Підсумок ----------${N}"
echo " Режим:        $([[ $MODE == 1 ]] && echo 'TigerVNC (віртуальний стіл)' || echo 'x11vnc (поточний екран)')"
echo " Користувач:   $VUSER"
echo " Порт:         $PORT"
[[ "$MODE" == "1" ]] && echo " Роздільність: $RES, середовище: $DE"
echo " Доступ:       $([[ $LOCAL_ONLY == yes ]] && echo "через SSH-тунель (порт $SSH_PORT)" || echo 'напряму')"
echo " Адреса:       $SRV_ADDR"
echo " Автозапуск:   $AUTOSTART"
echo "${B}------------------------------${N}"
ask_yn "Все вірно? Починаємо встановлення" y || die "Скасовано."

# ---------- встановлення пакетів ----------
export DEBIAN_FRONTEND=noninteractive
info "Оновлюю список пакетів..."
apt-get update -y >/dev/null

if [[ "$MODE" == "1" ]]; then
  PKGS=(tigervnc-standalone-server tigervnc-common dbus-x11 xauth x11-xserver-utils)
  [[ "$DE" == "xfce" ]] && PKGS+=(xfce4 xfce4-goodies)
  [[ "$DE" == "mate" ]] && PKGS+=(mate-desktop-environment-core)
else
  PKGS=(x11vnc)
fi
info "Встановлюю: ${PKGS[*]}"
apt-get install -y "${PKGS[@]}"
ok "Пакети встановлено."

SERVICE_NAME=""
if [[ "$MODE" == "1" ]]; then
  # ----- TigerVNC -----
  mkdir -p "$HOME_DIR/.vnc"
  printf '%s' "$VNC_PASS" | vncpasswd -f > "$HOME_DIR/.vnc/passwd"
  case "$DE" in
    xfce)   SESSION_CMD="startxfce4" ;;
    mate)   SESSION_CMD="mate-session" ;;
    custom) SESSION_CMD="$DE_CMD" ;;
  esac
  cat > "$HOME_DIR/.vnc/xstartup" <<EOF
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "\$HOME/.Xresources" ] && xrdb "\$HOME/.Xresources"
exec $SESSION_CMD
EOF
  chmod 700 "$HOME_DIR/.vnc/xstartup"
  chmod 600 "$HOME_DIR/.vnc/passwd"
  chown -R "$VUSER":"$(id -gn "$VUSER")" "$HOME_DIR/.vnc"

  SERVICE_NAME="vnc-${VUSER}-${DISPLAY_NUM}.service"
  HN="$(hostname)"
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=TigerVNC server for $VUSER on :$DISPLAY_NUM
After=network.target

[Service]
Type=forking
User=$VUSER
PAMName=login
PIDFile=$HOME_DIR/.vnc/${HN}:${DISPLAY_NUM}.pid
ExecStartPre=-/usr/bin/vncserver -kill :$DISPLAY_NUM
ExecStart=/usr/bin/vncserver :$DISPLAY_NUM -geometry $RES -depth 24 -localhost $LOCAL_ONLY
ExecStop=/usr/bin/vncserver -kill :$DISPLAY_NUM
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
else
  # ----- x11vnc -----
  x11vnc -storepasswd "$VNC_PASS" /etc/x11vnc.pass >/dev/null
  chmod 600 /etc/x11vnc.pass
  LOCAL_FLAG=""; [[ "$LOCAL_ONLY" == "yes" ]] && LOCAL_FLAG="-localhost"
  SERVICE_NAME="x11vnc-custom.service"
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=x11vnc (share current screen)
After=display-manager.service network.target

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display :0 -auth guess -forever -shared -noxdamage -rfbauth /etc/x11vnc.pass -rfbport $PORT $LOCAL_FLAG
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
if [[ "$AUTOSTART" == "y" ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; fi
systemctl restart "$SERVICE_NAME" || warn "Сервіс не стартував. Дивіться: journalctl -u $SERVICE_NAME -e"
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then ok "Сервіс $SERVICE_NAME працює."
else warn "Сервіс неактивний — перевірте логи."; fi

# ---------- брандмауер ----------
if [[ "$USE_UFW" == "y" ]]; then
  if [[ "$LOCAL_ONLY" == "yes" ]]; then
    ufw allow "$SSH_PORT"/tcp >/dev/null && ok "ufw: відкрито SSH ($SSH_PORT)."
  else
    if [[ -n "$ALLOW_FROM" ]]; then ufw allow from "$ALLOW_FROM" to any port "$PORT" proto tcp >/dev/null
    else ufw allow "$PORT"/tcp >/dev/null; fi
    ok "ufw: відкрито порт $PORT."
  fi
  ufw status | grep -qi inactive && warn "ufw вимкнений. Увімкнути: sudo ufw enable (спершу переконайтесь, що SSH дозволений!)"
fi

# ---------- файли "підключення в 1 клік" ----------
OUT_DIR="$HOME_DIR/vnc-connect"
mkdir -p "$OUT_DIR"
LPORT="$PORT"

if [[ "$LOCAL_ONLY" == "yes" ]]; then
  # --- Windows (.bat): тунель + viewer ---
  cat > "$OUT_DIR/connect-windows.bat" <<EOF
@echo off
REM Підключення в 1 клік (SSH-тунель + VNC viewer). Потрібні: OpenSSH (є у Windows 10/11) і TigerVNC/RealVNC Viewer.
echo Відкриваю SSH-тунель до $SRV_ADDR ...
start "VNC-tunnel" /min ssh -N -L $LPORT:localhost:$PORT -p $SSH_PORT $VUSER@$SRV_ADDR
timeout /t 4 >nul
where vncviewer >nul 2>nul && (start "" vncviewer localhost::$LPORT) || (
  if exist "%ProgramFiles%\\TigerVNC\\vncviewer.exe" (start "" "%ProgramFiles%\\TigerVNC\\vncviewer.exe" localhost::$LPORT) else (
  if exist "%ProgramFiles%\\RealVNC\\VNC Viewer\\vncviewer.exe" (start "" "%ProgramFiles%\\RealVNC\\VNC Viewer\\vncviewer.exe" localhost:$LPORT) else (
    echo VNC Viewer не знайдено. Встановіть TigerVNC або RealVNC Viewer і підключіться до localhost:$LPORT
    pause)))
EOF
  # --- Linux/macOS (.sh) ---
  cat > "$OUT_DIR/connect-linux-mac.sh" <<EOF
#!/usr/bin/env bash
# Підключення в 1 клік: SSH-тунель + VNC viewer
ssh -f -N -L $LPORT:localhost:$PORT -p $SSH_PORT $VUSER@$SRV_ADDR || exit 1
sleep 2
if command -v vncviewer >/dev/null; then vncviewer localhost::$LPORT
elif command -v remmina >/dev/null; then remmina -c vnc://localhost:$LPORT
elif [ "\$(uname)" = "Darwin" ]; then open vnc://localhost:$LPORT
else echo "Встановіть vncviewer (tigervnc-viewer) і підключіться до localhost:$LPORT"; fi
EOF
  chmod +x "$OUT_DIR/connect-linux-mac.sh"
  TIGER_HOST="localhost::$LPORT"
else
  cat > "$OUT_DIR/connect-windows.bat" <<EOF
@echo off
where vncviewer >nul 2>nul && (start "" vncviewer $SRV_ADDR::$PORT) || (
  if exist "%ProgramFiles%\\TigerVNC\\vncviewer.exe" (start "" "%ProgramFiles%\\TigerVNC\\vncviewer.exe" $SRV_ADDR::$PORT) else (
  if exist "%ProgramFiles%\\RealVNC\\VNC Viewer\\vncviewer.exe" (start "" "%ProgramFiles%\\RealVNC\\VNC Viewer\\vncviewer.exe" $SRV_ADDR:$PORT) else (
    echo Встановіть VNC Viewer і підключіться до $SRV_ADDR:$PORT
    pause)))
EOF
  cat > "$OUT_DIR/connect-linux-mac.sh" <<EOF
#!/usr/bin/env bash
if command -v vncviewer >/dev/null; then vncviewer $SRV_ADDR::$PORT
elif command -v remmina >/dev/null; then remmina -c vnc://$SRV_ADDR:$PORT
elif [ "\$(uname)" = "Darwin" ]; then open vnc://$SRV_ADDR:$PORT
else echo "Встановіть vncviewer і підключіться до $SRV_ADDR:$PORT"; fi
EOF
  chmod +x "$OUT_DIR/connect-linux-mac.sh"
  TIGER_HOST="$SRV_ADDR::$PORT"
fi

# Конфіг-файли для подвійного кліку у viewer-ах
cat > "$OUT_DIR/connect.tigervnc" <<EOF
TigerVNC Configuration file Version 1.0

ServerName=$TIGER_HOST
EOF
cat > "$OUT_DIR/connect.vnc" <<EOF
[Connection]
Host=$([[ $LOCAL_ONLY == yes ]] && echo "localhost:$LPORT" || echo "$SRV_ADDR:$PORT")
EOF
chown -R "$VUSER":"$(id -gn "$VUSER")" "$OUT_DIR"

# ---------- фінал ----------
echo
echo "${G}=============== ГОТОВО ===============${N}"
echo " Сервіс:         $SERVICE_NAME"
echo " Файли для 1-клік підключення (скопіюйте на свій комп'ютер):"
echo "   $OUT_DIR/"
echo "     connect-windows.bat      — Windows: двічі клікнути"
echo "     connect-linux-mac.sh     — Linux/macOS"
echo "     connect.tigervnc / .vnc  — відкрити у TigerVNC / RealVNC Viewer"
echo
if [[ "$LOCAL_ONLY" == "yes" ]]; then
  echo " Вручну:  ssh -L $LPORT:localhost:$PORT -p $SSH_PORT $VUSER@$SRV_ADDR"
  echo "          потім VNC Viewer -> localhost:$LPORT"
else
  echo " Вручну:  VNC Viewer -> $SRV_ADDR:$PORT"
  warn "Трафік не шифрується. Для інтернету краще SSH-тунель або VPN."
fi
echo
echo " Керування:  systemctl status|restart|stop $SERVICE_NAME"
echo " Видалення:  запустіть скрипт ще раз і оберіть пункт 2"
echo "${G}======================================${N}"

# =============================================================================
#  Передача файлів підключення на ваш комп'ютер
# =============================================================================
echo
echo "Як передати файли підключення на ваш комп'ютер?"
echo "  1) Скопіювати автоматично (scp) — скрипт сам надішле, потрібен пароль/ключ вашого ПК"
echo "  2) Тимчасове посилання для завантаження через браузер (5 хвилин)"
echo "  3) Не потрібно, заберу сам"
ask "Ваш вибір" "2"; SEND="$REPLY_VAL"

case "$SEND" in
  1)
    echo
    echo "На вашому ПК має працювати SSH-сервер (Linux/macOS: sshd; Windows: 'OpenSSH Server')"
    echo "і сервер має бачити ваш ПК у мережі. Якщо ні — оберіть варіант 2."
    echo "  1) Windows"
    echo "  2) Linux / macOS"
    ask "Ваша ОС" "1"; CLI_OS="$REPLY_VAL"
    ask "IP-адреса вашого комп'ютера" ""; CLI_HOST="$REPLY_VAL"
    [[ -n "$CLI_HOST" ]] || die "IP не вказано."
    ask "Ім'я користувача на вашому комп'ютері" ""; CLI_USER="$REPLY_VAL"
    [[ -n "$CLI_USER" ]] || die "Ім'я користувача не вказано."
    ask "SSH-порт вашого комп'ютера" "22"; CLI_PORT="$REPLY_VAL"
    if [[ "$CLI_OS" == "1" ]]; then CLI_DIR_DEF="C:/Users/$CLI_USER/Desktop/"; else CLI_DIR_DEF="~/"; fi
    ask "Куди скопіювати" "$CLI_DIR_DEF"; CLI_DIR="$REPLY_VAL"
    info "Копіюю... (якщо попросить — введіть пароль вашого комп'ютера)"
    if scp -o StrictHostKeyChecking=accept-new -P "$CLI_PORT" -r "$OUT_DIR"/. "$CLI_USER@$CLI_HOST:$CLI_DIR"; then
      ok "Файли скопійовано в $CLI_DIR на $CLI_HOST."
    else
      warn "Не вдалося скопіювати. Спробуйте варіант 2 (посилання) або заберіть файли з $OUT_DIR"
    fi
    ;;
  2)
    command -v python3 >/dev/null || apt-get install -y python3 >/dev/null
    ask "Порт для тимчасового посилання" "8000"; HTTP_PORT="$REPLY_VAL"
    ask "Лише з вашого IP (порожньо = з будь-якого)" ""; HTTP_FROM="$REPLY_VAL"
    UFW_RULE=0
    if command -v ufw >/dev/null && ufw status | grep -qi "Status: active"; then
      if [[ -n "$HTTP_FROM" ]]; then ufw allow from "$HTTP_FROM" to any port "$HTTP_PORT" proto tcp >/dev/null
      else ufw allow "$HTTP_PORT"/tcp >/dev/null; fi
      UFW_RULE=1
    fi
    echo
    ok "Відкрийте в браузері на своєму ПК:"
    echo "     ${G}http://$SRV_ADDR:$HTTP_PORT/${N}"
    warn "Це незашифрований HTTP; у файлах немає пароля, лише адреса. Зупиниться через 5 хв або по Enter."
    ( cd "$OUT_DIR" && exec timeout 300 python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
    HTTP_PID=$!
    read -r -t 300 -p "Натисніть Enter, коли завантажите файли... " _ || true
    kill "$HTTP_PID" 2>/dev/null || true
    if [[ "$UFW_RULE" == "1" ]]; then
      if [[ -n "$HTTP_FROM" ]]; then ufw delete allow from "$HTTP_FROM" to any port "$HTTP_PORT" proto tcp >/dev/null 2>&1 || true
      else ufw delete allow "$HTTP_PORT"/tcp >/dev/null 2>&1 || true; fi
    fi
    ok "Тимчасовий сервер зупинено, порт закрито."
    ;;
  *) info "Файли лежать у $OUT_DIR" ;;
esac
