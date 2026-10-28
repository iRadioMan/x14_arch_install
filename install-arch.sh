#!/usr/bin/env bash
# =============================================================================
#  install-arch.sh
#  Автоматическая установка Arch Linux на Honor MagicBook X14 2025
#  (Core 5 220H / 32 GB DDR4 / Intel Xe-LP iGPU / 1 TB NVMe)
#
#  Запуск из загруженного установочного образа Arch Linux (UEFI, root):
#      bash install-arch.sh
#
#  Скрипт спрашивает ТОЛЬКО:
#    1) диск для установки (выбор из списка)
#    2) парольную фразу для LUKS2
#  Всё остальное делает сам.
#
#  ВНИМАНИЕ: целевой диск будет полностью очищен.
#  Лог: /tmp/arch-install-*.log
# =============================================================================
setfont ter-v32b
set -Eeuo pipefail
umask 022

# -----------------------------------------------------------------------------
#  НАСТРОЙКИ
# -----------------------------------------------------------------------------
HOSTNAME_="rad-laptop"
TIMEZONE_="Asia/Barnaul"

LOCALE_PRIMARY="ru_RU.UTF-8"
LOCALES_TO_ENABLE=("en_US.UTF-8 UTF-8" "ru_RU.UTF-8 UTF-8")

# Раскладка консоли/initramfs. US — чтобы пароль LUKS всегда вводился в одной
# раскладке. Русская раскладка настраивается отдельно для KDE (Alt+Shift).
CONSOLE_KEYMAP="us"

USERNAME_="radioman"
USER_FULLNAME="rad.io"
USER_SHELL_="/usr/bin/fish"
# ВНИМАНИЕ: пароль в открытом виде и он очень слабый. Смените после установки.
USER_PASSWORD="123456"

ESP_SIZE="300M"
BOOT_SIZE="1G"
SWAP_SIZE="8G"

CRYPT_NAME="cryptroot"
BTRFS_OPTS="noatime,compress=zstd:1,ssd,discard=async"

# Пропускать TRIM через dm-crypt: yes/no.
# Плюс: скорость и ресурс SSD. Минус: dm-crypt сообщает, какие блоки свободны.
LUKS_ALLOW_DISCARDS="yes"

BOOTLOADER_ID="GRUB"
KERNEL_PKGS=(linux linux-lts linux-headers)

PKGS_SYSTEM=(
  base base-devel
  "${KERNEL_PKGS[@]}" linux-firmware intel-ucode
  btrfs-progs cryptsetup grub efibootmgr dosfstools e2fsprogs
  sudo fish nano vim git wget curl zstd
  networkmanager wpa_supplicant bluez bluez-utils
  sof-firmware alsa-ucm-conf alsa-utils
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  power-profiles-daemon
  reflector man-db man-pages
  openssh htop fastfetch mc ntfs-3g p7zip ncdu powertop nvtop lm_sensors
  mesa vulkan-intel intel-media-driver libva-utils intel-gpu-tools
  noto-fonts noto-fonts-cjk ttf-liberation
  snapper snap-pac grub-btrfs inotify-tools
  xdg-user-dirs
)

# plasma или plasma-meta
PLASMA_TARGET="plasma"

PKGS_DESKTOP=(
  sddm
  dolphin konsole kate ark okular gwenview
  kio-extras ffmpegthumbs
)

PKGS_APPS=(
  telegram-desktop qbittorrent audacious audacious-plugins
  obs-studio easyeffects lsp-plugins-lv2
  libreoffice-fresh-ru smplayer opencode
)

AUR_PKGS=(google-chrome vesktop-bin photocraft-bin wordcraft-bin vscodium-bin)

# -----------------------------------------------------------------------------
#  Вспомогательное
# -----------------------------------------------------------------------------
LOG="/tmp/arch-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'

msg()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '\n%sОШИБКА:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

trap 'rc=$?; printf "\n%sСкрипт остановлен%s (код %s, строка %s). Лог: %s\n" "$C_R" "$C_0" "$rc" "$LINENO" "$LOG" >&2' ERR

# Ввод всегда с терминала: важно, если скрипт запущен через `curl | bash`
ask()  { local __p="$1" __v=""; read -r -p "$__p" __v </dev/tty; printf '%s' "$__v"; }
asks() { local __p="$1" __v=""; read -r -s -p "$__p" __v </dev/tty; printf '%s' "$__v"; }

# -----------------------------------------------------------------------------
#  0. Проверки окружения
# -----------------------------------------------------------------------------
msg "Проверка окружения"

[[ $EUID -eq 0 ]] || die "Скрипт нужно запускать от root (в live-среде Arch)."
[[ -d /sys/firmware/efi ]] || die "Система загружена не в UEFI-режиме. Включите UEFI в BIOS и загрузите образ заново."

if [[ -d /run/archiso ]]; then
  ok "Обнаружена live-среда Arch Linux"
else
  warn "Не похоже на live-среду Arch. Продолжаю, но будьте осторожны."
fi

for bin in pacstrap sgdisk cryptsetup mkfs.btrfs; do
  command -v "$bin" >/dev/null || die "Не найдена утилита: $bin"
done

ping -c1 -W3 -q archlinux.org >/dev/null 2>&1 \
  || die "Нет доступа в интернет. Подключите сеть (iwctl / nmtui) и запустите скрипт снова."
ok "Интернет доступен"

timedatectl set-ntp true >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
#  1. Зеркала и выбор целевых пакетов
# -----------------------------------------------------------------------------
msg "Обновление списка зеркал"
if command -v reflector >/dev/null; then
  cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak 2>/dev/null || true
  if ! reflector --country RU,BY,KZ --age 24 --protocol https --latest 20 \
                 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    if ! reflector --latest 20 --protocol https --sort rate \
                   --save /etc/pacman.d/mirrorlist 2>/dev/null; then
      warn "reflector не смог подобрать зеркала, оставляю исходный список"
      cp /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist 2>/dev/null || true
    fi
  fi
fi
pacman -Sy --noconfirm >/dev/null
ok "Списки пакетов обновлены"

verify_pkgs() {
  local p out=() missing=()
  for p in "$@"; do
    # base-devel и подобные — это группы, а не пакеты
    if pacman -Si "$p" >/dev/null 2>&1 || pacman -Sg "$p" >/dev/null 2>&1; then
      out+=("$p")
    else
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    warn "Пропущены (нет в репозиториях): ${missing[*]}"
  fi
  if (( ${#out[@]} > 0 )); then
    printf '%s\n' "${out[@]}"
  fi
}

mapfile -t ALL_PKGS < <(verify_pkgs "${PKGS_SYSTEM[@]}" "$PLASMA_TARGET" "${PKGS_DESKTOP[@]}" "${PKGS_APPS[@]}")
ok "К установке: ${#ALL_PKGS[@]} пакетов"

# -----------------------------------------------------------------------------
#  2. Выбор диска
# -----------------------------------------------------------------------------
msg "Поиск накопителей"

mapfile -t DISK_LINES < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | sed '/^$/d')
[[ ${#DISK_LINES[@]} -gt 0 ]] || die "Не найдено ни одного диска."

# Диск, с которого загружен live-образ, стирать нельзя
LIVE_DISK=""
LIVE_SRC="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
if [[ -n "$LIVE_SRC" ]]; then
  LIVE_PK="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null | head -n1 || true)"
  if [[ -n "$LIVE_PK" ]]; then
    LIVE_DISK="/dev/$LIVE_PK"
  fi
fi

printf '\n'
for i in "${!DISK_LINES[@]}"; do
  line="${DISK_LINES[$i]}"
  dev="$(awk '{print $1}' <<<"$line")"
  size="$(awk '{print $2}' <<<"$line")"
  model="$(awk '{$1="";$2="";sub(/^[[:space:]]+/,"");print}' <<<"$line")"
  mark=""
  if [[ "$dev" == "$LIVE_DISK" ]]; then
    mark=" ${C_Y}(live-USB, недоступен)${C_0}"
  fi
  printf '  [%d] %-16s %8s  %s%s\n' "$i" "$dev" "$size" "${model:-unknown}" "$mark"
done
printf '\n'

DISK=""
while :; do
  ans="$(ask 'Введите номер диска для установки: ')"
  [[ "$ans" =~ ^[0-9]+$ ]] || { warn "Нужен номер из списка"; continue; }
  ans=$((10#$ans))
  (( ans < ${#DISK_LINES[@]} )) || { warn "Нет такого номера"; continue; }
  cand="$(awk '{print $1}' <<<"${DISK_LINES[$ans]}")"
  if [[ "$cand" == "$LIVE_DISK" ]]; then
    warn "Это носитель с live-образом, выберите другой"
    continue
  fi
  DISK="$cand"
  break
done

[[ -b "$DISK" ]] || die "$DISK не является блочным устройством."
[[ "$(lsblk -dno TYPE "$DISK")" == "disk" ]] || die "$DISK не является целым диском."

DISK_SIZE_B="$(blockdev --getsize64 "$DISK")"
(( DISK_SIZE_B > 32*1024*1024*1024 )) || die "Диск меньше 32 ГБ — этого мало."

case "$DISK" in
  *nvme*|*mmcblk*|*loop*) P="${DISK}p" ;;
  *)                      P="$DISK"   ;;
esac
ESP_PART="${P}1"
BOOT_PART="${P}2"
CRYPT_PART="${P}3"

printf '\n%s\n' "${C_R}ВНИМАНИЕ! Диск $DISK будет ПОЛНОСТЬЮ ОЧИЩЕН.${C_0}"
printf 'Все данные на нём будут уничтожены.\n\n'
confirm="$(ask "Для продолжения введите путь к диску ($DISK): ")"
[[ "$confirm" == "$DISK" ]] || die "Подтверждение не совпало. Выход."

# -----------------------------------------------------------------------------
#  3. Парольная фраза LUKS
# -----------------------------------------------------------------------------
msg "Парольная фраза LUKS2"
warn "Пароль LUKS вводится в консоли в US-раскладке."
LUKS_PASS=""
while :; do
  p1="$(asks 'Парольная фраза: ')"
  printf '\n'
  p2="$(asks 'Повторите фразу: ')"
  printf '\n'
  if [[ "$p1" != "$p2" ]]; then
    warn "Фразы не совпадают, попробуйте снова"
    continue
  fi
  if (( ${#p1} < 8 )); then
    warn "Слишком короткая (минимум 8 символов)"
    continue
  fi
  if (( ${#p1} < 12 )); then
    warn "Короткая фраза — для шифрования диска рекомендуется 20+ символов"
  fi
  LUKS_PASS="$p1"
  break
done
unset p1 p2

# -----------------------------------------------------------------------------
#  4. Разметка, LUKS, файловые системы
# -----------------------------------------------------------------------------
msg "Размонтирование старых точек (если есть)"
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
cryptsetup close "$CRYPT_NAME" 2>/dev/null || true

msg "Создание таблицы разделов GPT на $DISK"
sgdisk --zap-all "$DISK"
sgdisk -n "1:0:+${ESP_SIZE}"  -t 1:ef00 -c 1:"EFI"       \
       -n "2:0:+${BOOT_SIZE}" -t 2:8300 -c 2:"BOOT"      \
       -n "3:0:0"             -t 3:8300 -c 3:"CRYPTROOT" "$DISK"
partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
udevadm settle

for _ in {1..40}; do
  if [[ -b "$CRYPT_PART" ]]; then
    break
  fi
  sleep 0.25
done
[[ -b "$CRYPT_PART" ]] || die "Разделы не появились: $CRYPT_PART"
ok "Разделы: $ESP_PART (ESP), $BOOT_PART (/boot), $CRYPT_PART (LUKS2)"

msg "Форматирование EFI и /boot"
mkfs.fat -F 32 -n EFI "$ESP_PART" >/dev/null
mkfs.ext4 -q -m 0 -L BOOT "$BOOT_PART"
ok "FAT32 (ESP) + ext4 (/boot) готовы"

msg "Создание LUKS2-контейнера"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --label "$CRYPT_NAME" \
  "$CRYPT_PART" -
ok "LUKS2 создан (argon2id, AES-XTS-512)"

LUKS_UUID="$(cryptsetup luksUUID "$CRYPT_PART")"

CRYPT_OPEN_OPTS=(--key-file -)
if [[ "$LUKS_ALLOW_DISCARDS" == "yes" ]]; then
  CRYPT_OPEN_OPTS+=(--allow-discards)
fi
printf '%s' "$LUKS_PASS" | cryptsetup open "${CRYPT_OPEN_OPTS[@]}" "$CRYPT_PART" "$CRYPT_NAME"
unset LUKS_PASS
ok "Контейнер открыт как /dev/mapper/$CRYPT_NAME"

msg "Создание BTRFS и сабтомов"
mkfs.btrfs -f -L ARCH "/dev/mapper/$CRYPT_NAME" >/dev/null
ROOT_UUID="$(blkid -s UUID -o value "/dev/mapper/$CRYPT_NAME")"

mount "/dev/mapper/$CRYPT_NAME" /mnt
btrfs subvolume create /mnt/@     >/dev/null
btrfs subvolume create /mnt/@home >/dev/null
btrfs subvolume create /mnt/@swap >/dev/null
umount /mnt

mount -o "$BTRFS_OPTS,subvol=@"      "/dev/mapper/$CRYPT_NAME" /mnt
mkdir -p /mnt/home /mnt/swap /mnt/boot
mount -o "$BTRFS_OPTS,subvol=@home"  "/dev/mapper/$CRYPT_NAME" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@swap"  "/dev/mapper/$CRYPT_NAME" /mnt/swap
mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$ESP_PART"  /mnt/boot/efi
ok "Сабтомы @, @home, @swap смонтированы"

msg "Создание swap-файла ${SWAP_SIZE} в /swap"
chattr +C /mnt/swap
if ! btrfs filesystem mkswapfile --size "$SWAP_SIZE" --uuid clear /mnt/swap/swapfile 2>/dev/null; then
  warn "btrfs mkswapfile недоступен, создаю файл вручную"
  # Парсим размер: 8G -> 8192 MB, 8M -> 8 MB, 8 -> 8 MB
  size_num="${SWAP_SIZE%%[A-Za-z]*}"
  size_unit="${SWAP_SIZE##*[0-9]}"
  size_unit="${size_unit^^}"
  size_mb=$size_num
  case "$size_unit" in
    G|GB) size_mb=$((size_num * 1024)) ;;
    M|MB) size_mb=$size_num ;;
    K|KB) size_mb=$((size_num / 1024)) ;;
    *) size_mb=$size_num ;;  # default MB
  esac
  dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count="$size_mb" status=none
  chmod 600 /mnt/swap/swapfile
  mkswap -U clear /mnt/swap/swapfile >/dev/null
fi
chmod 600 /mnt/swap/swapfile
ok "swap-файл создан"

msg "Генерация /etc/fstab"
mkdir -p /mnt/etc
genfstab -U /mnt | awk '$3 != "swap"' > /mnt/etc/fstab
printf '/swap/swapfile none swap defaults 0 0\n' >> /mnt/etc/fstab
swapon /mnt/swap/swapfile
ok "fstab готов, swap подключён"

# -----------------------------------------------------------------------------
#  5. Установка пакетов
# -----------------------------------------------------------------------------
msg "Установка пакетов (самый долгий этап). Пожалуйста, подождите, прогресс отображается только в логе..."
if ! pacstrap -K /mnt "${ALL_PKGS[@]}"; then
  warn "Первый проход pacstrap не удался, повтор через 10 секунд"
  sleep 10
  pacstrap -K /mnt "${ALL_PKGS[@]}"
fi
ok "Пакеты установлены"

# переносим подобранный список зеркал в новую систему
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist 2>/dev/null || true

# -----------------------------------------------------------------------------
#  6. Настройка системы в chroot
# -----------------------------------------------------------------------------
msg "Подготовка переменных для chroot"
{
  printf 'HOSTNAME_=%q\n'      "$HOSTNAME_"
  printf 'TIMEZONE_=%q\n'      "$TIMEZONE_"
  printf 'LOCALE_PRIMARY=%q\n' "$LOCALE_PRIMARY"
  printf 'CONSOLE_KEYMAP=%q\n' "$CONSOLE_KEYMAP"
  printf 'USERNAME_=%q\n'      "$USERNAME_"
  printf 'USER_FULLNAME=%q\n'  "$USER_FULLNAME"
  printf 'USER_SHELL_=%q\n'    "$USER_SHELL_"
  printf 'USER_PASSWORD=%q\n'  "$USER_PASSWORD"
  printf 'LUKS_UUID=%q\n'      "$LUKS_UUID"
  printf 'ROOT_UUID=%q\n'      "$ROOT_UUID"
  printf 'CRYPT_NAME=%q\n'     "$CRYPT_NAME"
  printf 'LUKS_ALLOW_DISCARDS=%q\n' "$LUKS_ALLOW_DISCARDS"
  printf 'BOOTLOADER_ID=%q\n'  "$BOOTLOADER_ID"
  printf 'LOCALES_TO_ENABLE=(%s)\n' "$(printf '%q ' "${LOCALES_TO_ENABLE[@]}")"
} > /mnt/root/vars.env
chmod 600 /mnt/root/vars.env

cat > /mnt/root/chroot-setup.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/vars.env

echo "--- часовой пояс"
ln -sf "/usr/share/zoneinfo/${TIMEZONE_}" /etc/localtime
hwclock --systohc

echo "--- локали"
for entry in "${LOCALES_TO_ENABLE[@]}"; do
  # Экранируем спецсимволы regex, чтобы "." в "UTF-8" не значила "любой символ"
  entry_re="$(printf '%s' "$entry" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  # Ищем строку точно с этой локалью и раскомментируем
  if grep -q "^#.*${entry_re}" /etc/locale.gen; then
    sed -i "s/^#\(${entry_re}\)/\1/" /etc/locale.gen
  elif ! grep -q "^${entry_re}" /etc/locale.gen; then
    # Если вообще не найдена — добавляем
    printf '%s\n' "$entry" >> /etc/locale.gen
  fi
done
locale-gen
printf 'LANG=%s\n' "$LOCALE_PRIMARY" > /etc/locale.conf
printf 'LC_MESSAGES=C\n' >> /etc/locale.conf
printf 'KEYMAP=%s\n' "$CONSOLE_KEYMAP" > /etc/vconsole.conf

echo "--- hostname"
printf '%s\n' "$HOSTNAME_" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_}.localdomain ${HOSTNAME_}
EOF

echo "--- networkmanager"
# Отключаем проверку connectivity (запрос connectivity-check.archlinux.org).
# Иначе при использовании Mihomo/Clash NetworkManager считает сеть офлайн
# и рисует восклицательный знак в трее.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-connectivity.conf <<'EOF'
[connectivity]
enabled=false
EOF

echo "--- sysctl"
cat > /etc/sysctl.d/99-desktop.conf <<'EOF'
# swap только при реальной нехватке RAM
vm.swappiness = 10
vm.vfs_cache_pressure = 50
# меньше лишних записей на NVMe
vm.dirty_writeback_centisecs = 1500
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.page-cluster = 0
EOF
sysctl --system >/dev/null

echo "--- pacman"
sed -i 's/^#Color/Color/' /etc/pacman.conf
# Добавляем ILoveCandy если его нет
if ! grep -q '^ILoveCandy' /etc/pacman.conf && ! grep -q '^#ILoveCandy' /etc/pacman.conf; then
  sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
else
  sed -i 's/^#ILoveCandy/ILoveCandy/' /etc/pacman.conf
fi
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

echo "--- initramfs"
if [[ -f /usr/lib/initcpio/install/microcode ]]; then
  HOOKS_LINE="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
else
  HOOKS_LINE="base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
fi
sed -i "s|^HOOKS=.*|HOOKS=(${HOOKS_LINE})|" /etc/mkinitcpio.conf
sed -i 's|^MODULES=.*|MODULES=(i915)|' /etc/mkinitcpio.conf
sed -i 's|^COMPRESSION=.*|COMPRESSION="zstd"|' /etc/mkinitcpio.conf
mkinitcpio -P

echo "--- root"
passwd -l root >/dev/null

echo "--- пользователь ${USERNAME_}"
if ! id "$USERNAME_" >/dev/null 2>&1; then
  useradd -m -G wheel -s "$USER_SHELL_" -c "$USER_FULLNAME" "$USERNAME_"
  chown -R "$USERNAME_:$USERNAME_" "/home/$USERNAME_"
fi
printf '%s:%s\n' "$USERNAME_" "$USER_PASSWORD" | chpasswd
grep -qx "$USER_SHELL_" /etc/shells || printf '%s\n' "$USER_SHELL_" >> /etc/shells
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

echo "--- GRUB"
CMDLINE="cryptdevice=UUID=${LUKS_UUID}:${CRYPT_NAME}"
if [[ "$LUKS_ALLOW_DISCARDS" == "yes" ]]; then
  CMDLINE+=":allow-discards"
fi
CMDLINE+=" root=UUID=${ROOT_UUID} rootflags=subvol=@"

sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${CMDLINE}\"|" /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"|' /etc/default/grub
sed -i 's|^#\?GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub

grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id="$BOOTLOADER_ID" \
             --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "--- snapper"
# В chroot snapper часто не работает из-за отсутствия D-Bus.
# Создаём конфигурацию вручную и настроим через systemd при первой загрузке.
echo "snapper: создание конфигурации отложено до первой загрузки"
cat > /etc/systemd/system/snapper-firstboot.service <<'UNIT'
[Unit]
Description=Create snapper root config on first boot
ConditionPathExists=!/etc/snapper/configs/root
After=dbus.service
Wants=dbus.service

[Service]
Type=oneshot
ExecStart=/usr/bin/snapper -c root create-config /
ExecStartPost=/usr/bin/snapper -c root set-config TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=4 TIMELINE_LIMIT_MONTHLY=6 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=10
ExecStartPost=-/usr/bin/systemctl restart grub-btrfsd.service

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable snapper-firstboot.service

echo "--- службы"
systemctl enable NetworkManager.service
systemctl enable sddm.service
systemctl enable bluetooth.service
systemctl enable systemd-timesyncd.service
systemctl enable power-profiles-daemon.service
systemctl enable snapper-timeline.timer snapper-cleanup.timer
systemctl enable grub-btrfsd.service
systemctl enable fstrim.timer

echo "--- датчики"
sensors-detect --auto >/dev/null 2>&1 || true

echo "--- готово"
CHROOT_EOF

chmod +x /mnt/root/chroot-setup.sh
msg "Настройка системы (chroot)"
arch-chroot /mnt /root/chroot-setup.sh
rm -f /mnt/root/chroot-setup.sh /mnt/root/vars.env
ok "Система настроена"

# -----------------------------------------------------------------------------
#  7. AUR (paru) и прикладные пакеты
# -----------------------------------------------------------------------------
msg "Установка paru и AUR-пакетов"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME_" > /mnt/etc/sudoers.d/99-aur-temp
chmod 440 /mnt/etc/sudoers.d/99-aur-temp

AUR_LIST="$(printf '%s ' "${AUR_PKGS[@]}")"
# Используем paru (не paru-bin), т.к. paru-bin часто отстаёт по версиям libalpm
if arch-chroot /mnt runuser -u "$USERNAME_" -- /bin/bash -lc "
set -e
export HOME=\"/home/$USERNAME_\"
# Обновляем базу пакетов в chroot перед сборкой
sudo pacman -Sy --noconfirm
cd /tmp
rm -rf paru
git clone --depth 1 https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
cd /tmp && rm -rf paru
mkdir -p \"\$HOME/.config/paru\"
printf '[options]\nBatchInstall\nSudoLoop\nPgpFetch\n' > \"\$HOME/.config/paru/paru.conf\"
paru -S --noconfirm --batchinstall ${AUR_LIST}
"; then
  ok "AUR-пакеты установлены"
else
  warn "AUR-пакеты поставить не удалось — система всё равно рабочая."
  warn "После первой загрузки выполните вручную:"
  warn "  paru -S --noconfirm ${AUR_PKGS[*]}"
fi

rm -f /mnt/etc/sudoers.d/99-aur-temp

# -----------------------------------------------------------------------------
#  8. Пользовательские настройки
# -----------------------------------------------------------------------------
msg "Настройка пользовательского окружения"
UHOME="/mnt/home/$USERNAME_"
mkdir -p "$UHOME/.config" "$UHOME/.local/share/applications"

# Русская раскладка в KDE, переключение Win+Space
cat > "$UHOME/.config/kxkbrc" <<'EOF'
[Layout]
Use=true
LayoutList=us,ru
VariantList=,
Model=pc105
Options=grp:win_space_toggle
ResetOldOptions=true
ShowLayoutIndicator=true
ShowSingle=false
SwitchMode=Global
EOF

# Аппаратное декодирование/кодирование видео в Chromium/Electron
HW_FLAGS="--enable-features=VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL --ignore-gpu-blocklist --ozone-platform-hint=auto"

make_override() {
  local name="$1" src="" dst=""
  src="/mnt/usr/share/applications/$name"
  if [[ ! -f "$src" ]]; then
    warn "Не найден $name — ярлык не изменён"
    return 0
  fi
  dst="$UHOME/.local/share/applications/$name"
  sed -E "s#^Exec=([^[:space:]]+)(.*)\$#Exec=\1 ${HW_FLAGS}\2#" "$src" > "$dst"
  ok "Ярлык с VA-API: $name"
}

make_override "google-chrome.desktop"
make_override "vesktop.desktop"

# -----------------------------------------------------------------------------
#  9. Завершение
# -----------------------------------------------------------------------------
msg "Размонтирование"
swapoff /mnt/swap/swapfile 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l -R /mnt 2>/dev/null || true
cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
ok "Всё размонтировано"

cat <<EOF

${C_G}================================================================${C_0}
 Установка завершена.

 Диск:         $DISK
 Разметка:     ESP ${ESP_SIZE} (FAT32) + /boot ${BOOT_SIZE} (ext4) + LUKS2 -> BTRFS
 Сабтомы:      @ (/), @home (/home), @swap (/swap)
 Swap:         ${SWAP_SIZE} файл, vm.swappiness=10
 Hostname:     $HOSTNAME_
 Пользователь: $USERNAME_ ($USER_FULLNAME), группа wheel
 Shell:        fish
 Ядро:         ${KERNEL_PKGS[0]}
 Загрузчик:    GRUB + grub-btrfs (снимки в меню)
 Пояс:         $TIMEZONE_
 Локаль:       $LOCALE_PRIMARY (+ en_US.UTF-8)

 Дальше:
   1) извлеките установочный носитель
   2) reboot
   3) пароль LUKS вводится в US-раскладке
   4) смените пароль: passwd

 Лог: $LOG
${C_G}================================================================${C_0}
EOF
