#!/usr/bin/env bash
# =============================================================================
#  vnc-reinstall.sh — швидке "почистити все і поставити заново" (Debian/Ubuntu/Kali)
#
#  Що робить:
#    * зносить старі VNC-сервіси, сесії, lock-файли
#    * ставить TigerVNC + XFCE + SSH-сервер (і лагодить SSH: ключі, запуск, порт)
#    * створює systemd-сервіс VNC з автозапуском, відкриває порти в ufw
#    * перевіряє, що порти реально слухають, і друкує адресу підключення
#
#  Запуск:   sudo bash vnc-reinstall.sh
#  Без питань:  sudo VNC_USER=kali VNC_PASS='мійпароль' bash vnc-reinstall.sh
# =============================================================================
set -uo pipefail

DISPLAY_NUM="${VNC_DISPLAY:-1}"
RES="${VNC_RES:-1920x1080}"
PORT=$((5900 + DISPLAY_NUM))

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
info() { echo "${B}[i]${N} $*"; }
ok()   { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[✗]${N} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустіть через sudo:  sudo bash $0"
command -v apt-get >/dev/null || die "Потрібна система на базі apt."

# ---------- єдині питання ----------
DEF_USER="${SUDO_USER:-}"
[[ "$DEF_USER" == "root" ]] && DEF_USER=""
if [[ -z "${VNC_USER:-}" ]]; then
  read -r -p "Користувач для VNC [${DEF_USER:-kali}]: " VNC_USER
  VNC_USER="${VNC_USER:-${DEF_USER:-kali}}"
fi
id "$VNC_USER" &>/dev/null || die "Користувача '$VNC_USER' не існує (створіть: adduser $VNC_USER)."
HOME_DIR="$(getent passwd "$VNC_USER" | cut -d: -f6)"
GROUP="$(id -gn "$VNC_USER")"

if [[ -z "${VNC_PASS:-}" ]]; then
  read -r -s -p "Пароль для VNC (1–8 символів значущі): " VNC_PASS; echo
  [[ -n "$VNC_PASS" ]] || die "Порожній пароль."
fi

SERVICE="vnc-${VNC_USER}-${DISPLAY_NUM}.service"

# ---------- 1. Повне очищення ----------
info "Прибираю старі VNC-сервіси та сесії..."
for u in /etc/systemd/system/vnc-*.service /etc/systemd/system/x11vnc-custom.service; do
  [[ -e "$u" ]] || continue
  systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
  rm -f "$u"
done
systemctl daemon-reload
pkill -u "$VNC_USER" Xtigervnc 2>/dev/null || true
pkill x11vnc 2>/dev/null || true
sleep 1
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
rm -f "$HOME_DIR"/.vnc/*.pid "$HOME_DIR"/.vnc/*.log 2>/dev/null || true
rm -f "$HOME_DIR/.vnc/passwd" "$HOME_DIR/.vnc/xstartup"
ok "Очищено."

# ---------- 2. Пакети ----------
export DEBIAN_FRONTEND=noninteractive
info "Оновлюю індекс пакетів..."
apt-get update -y >/dev/null 2>&1 || warn "apt update дав помилки (продовжую)."

info "Встановлюю TigerVNC, XFCE, SSH (кілька хвилин)..."
apt-get install -y tigervnc-standalone-server tigervnc-common \
  xfce4 xfce4-terminal dbus-x11 xauth x11-xserver-utils \
  openssh-server iproute2 netcat-openbsd >/tmp/vnc-apt.log 2>&1 \
  || { tail -20 /tmp/vnc-apt.log; die "Не вдалося встановити пакети (лог: /tmp/vnc-apt.log)."; }
apt-get install -y tigervnc-tools >/dev/null 2>&1 || true   # може не існувати — це нормально
command -v vncpasswd >/dev/null || die "vncpasswd не знайдено після встановлення."
[[ -x /usr/bin/vncserver ]]     || die "vncserver не знайдено після встановлення."
ok "Пакети встановлено."

# ---------- 3. SSH: ключі, конфіг, запуск ----------
info "Лагоджу SSH-сервер..."
ssh-keygen -A >/dev/null 2>&1                 # частa причина "connection refused": немає host-ключів
mkdir -p /run/sshd
if ! sshd -t 2>/tmp/sshd-test.log; then
  warn "Конфіг sshd з помилкою: $(cat /tmp/sshd-test.log). Відновлюю стандартний."
  [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.broken.$(date +%s)
  dpkg-reconfigure -f noninteractive openssh-server >/dev/null 2>&1 || true
fi
systemctl unmask ssh ssh.socket sshd 2>/dev/null || true
systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
sleep 2
SSH_PORT="$(ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | grep -x '22' | head -1)"
if [[ -z "$SSH_PORT" ]]; then
  SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')"
fi
if [[ -n "$SSH_PORT" ]]; then ok "SSH слухає порт $SSH_PORT."
else warn "SSH не піднявся. Дивіться: journalctl -u ssh -e --no-pager | tail -30"; fi

# ---------- 4. Налаштування VNC користувача ----------
info "Налаштовую VNC для $VNC_USER..."
install -d -o "$VNC_USER" -g "$GROUP" -m 700 "$HOME_DIR/.vnc"
printf '%s\n' "$VNC_PASS" | vncpasswd -f > "$HOME_DIR/.vnc/passwd"
cat > "$HOME_DIR/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
exec dbus-launch --exit-with-session startxfce4
EOF
chmod 600 "$HOME_DIR/.vnc/passwd"
chmod 755 "$HOME_DIR/.vnc/xstartup"
chown -R "$VNC_USER:$GROUP" "$HOME_DIR/.vnc"

# ---------- 5. systemd-сервіс (foreground — найнадійніше) ----------
cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=TigerVNC for $VNC_USER on :$DISPLAY_NUM
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$VNC_USER
Group=$GROUP
PAMName=login
WorkingDirectory=$HOME_DIR
ExecStartPre=-/bin/sh -c '/usr/bin/vncserver -kill :$DISPLAY_NUM >/dev/null 2>&1; rm -f /tmp/.X$DISPLAY_NUM-lock /tmp/.X11-unix/X$DISPLAY_NUM'
ExecStart=/usr/bin/vncserver :$DISPLAY_NUM -fg -geometry $RES -depth 24 -localhost no -SecurityTypes VncAuth
ExecStop=-/usr/bin/vncserver -kill :$DISPLAY_NUM
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

# ---------- 6. Брандмауер ----------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${SSH_PORT:-22}"/tcp >/dev/null
  ufw allow "$PORT"/tcp >/dev/null
  ok "ufw: відкрито порти ${SSH_PORT:-22} і $PORT."
fi

# ---------- 7. Перевірка ----------
info "Чекаю запуску VNC (до 20 с)..."
UP=0
for _ in $(seq 1 20); do
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$"; then UP=1; break; fi
  sleep 1
done

IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -n "$IP" ]] || IP="$(hostname -I | awk '{print $1}')"

if [[ "$UP" -ne 1 ]]; then
  echo
  warn "VNC не запустився. Останні логи сервісу:"
  journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null
  echo
  ls -1 "$HOME_DIR"/.vnc/*.log 2>/dev/null | head -1 | xargs -r tail -20
  die "Надішліть мені цей вивід — виправлю."
fi
ok "VNC слухає порт $PORT."

# ---------- 8. Файли підключення ----------
OUT="$HOME_DIR/vnc-connect"
install -d -o "$VNC_USER" -g "$GROUP" "$OUT"
cat > "$OUT/connect.tigervnc" <<EOF
TigerVNC Configuration file Version 1.0

ServerName=$IP::$PORT
EOF
cat > "$OUT/connect-linux-mac.sh" <<EOF
#!/usr/bin/env bash
exec vncviewer $IP::$PORT
EOF
cat > "$OUT/connect-windows.bat" <<EOF
@echo off
where vncviewer >nul 2>nul && (start "" vncviewer $IP::$PORT) || (start "" "%ProgramFiles%\\TigerVNC\\vncviewer.exe" $IP::$PORT)
EOF
cat > "$OUT/connect-ssh-tunnel.sh" <<EOF
#!/usr/bin/env bash
# Безпечний варіант: VNC через SSH-тунель
ssh -f -N -L $PORT:localhost:$PORT -p ${SSH_PORT:-22} $VNC_USER@$IP && vncviewer localhost::$PORT
EOF
chmod +x "$OUT"/*.sh
chown -R "$VNC_USER:$GROUP" "$OUT"

# ---------- 9. Підсумок ----------
echo
echo "${G}==================== ГОТОВО ====================${N}"
echo " VNC-адреса:     ${G}$IP::$PORT${N}      (пароль — той, що ви ввели)"
echo " Команда ПК:     vncviewer $IP::$PORT"
echo " SSH:            ssh -p ${SSH_PORT:-22} $VNC_USER@$IP"
echo " Файли в 1 клік: $OUT/"
echo
echo " Перевірка з вашого ПК:   nc -zv $IP $PORT   і   nc -zv $IP ${SSH_PORT:-22}"
echo " Керування:               systemctl status|restart $SERVICE"
echo " Логи:                    journalctl -u $SERVICE -e"
echo "${G}=================================================${N}"
warn "Підключення напряму не шифроване — для локальної мережі нормально, для інтернету використовуйте connect-ssh-tunnel.sh."
