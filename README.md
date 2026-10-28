# Автоустановка Arch Linux — Honor MagicBook X14 2025

Скрипт: `install-arch.sh`

## Использование

1. Записать образ Arch Linux на флешку, загрузиться в **UEFI**-режиме
   (Secure Boot в BIOS **выключить**, режим диска — AHCI/NVMe, не Intel RST/VMD).
2. Подключить интернет: `iwctl` (Wi-Fi) или `nmtui`.
3. Скачать и запустить скрипт:

```bash
curl -O https://example.invalid/install-arch.sh
bash install-arch.sh
```

4. Скрипт спросит **только**:
   - номер диска (с подтверждением вводом пути к диску);
   - парольную фразу LUKS2 (дважды).
5. После завершения — вынуть флешку и `reboot`.

Лог пишется в `/tmp/arch-install-*.log`.

## Что получится

| Параметр | Значение |
|---|---|
| Разметка | GPT: p1 ESP 300M FAT32, p2 /boot 1G ext4, p3 LUKS2 → BTRFS |
| BTRFS | сабтомы `@` (/), `@home` (/home), `@swap` (/swap) |
| Опции BTRFS | `noatime,compress=zstd:1,ssd,discard=async` |
| Swap | 8G файл `/swap/swapfile` (NOCOW), `vm.swappiness=10` |
| Загрузчик | GRUB (x86_64-efi) + grub-btrfs + snapper + snap-pac |
| Ядро | `linux` `linux-lts` + `intel-ucode`, early KMS `i915` |
| Часовой пояс | Asia/Barnaul |
| Локаль | `ru_RU.UTF-8` (основная), `en_US.UTF-8` |
| Hostname | `rad-laptop` |
| Пользователь | `radioman` (rad.io), группы `wheel`, shell `fish` |
| DE | KDE Plasma (Wayland), SDDM |
| GPU | `mesa`, `vulkan-intel`, `intel-media-driver` (VA-API/iHD) |

## Настройки

Все параметры — в блоке `НАСТРОЙКИ` в начале скрипта
(`ESP_SIZE`, `BOOT_SIZE`, `SWAP_SIZE`, `BTRFS_OPTS`, `LUKS_ALLOW_DISCARDS`,
списки пакетов, пароль, локаль, раскладка консоли и т.д.).

## Что скрипт НЕ делает

- не настраивает Secure Boot (sbctl/UKI);
- не настраивает спящий режим (hibernate) — swap-файл меньше объёма RAM;
- не настраивает firewall (ufw/nftables);
- не настраивает TPM2-авторазблокировку LUKS.
