#!/bin/bash
# Arch Openbox 설치 스크립트 (개선판)
# - GPT + LUKS 루트/홈, UKI(systemd-boot), Secure Boot(sbctl 선택적)
# - Openbox 경량 환경 자동 구성
# 주의: 디스크의 모든 데이터가 삭제됩니다!

set -euo pipefail

### ----- 설정값 (필요 시 변경) -----
target="/dev/sda"
rootmnt="/mnt"
locale="en_GB.UTF-8"
keymap="uk"
timezone="Europe/London"
hostname="arch-test"
username="walian"
# SHA512 해시 (mkpasswd -m sha-512 로 생성하고 $ 앞에 \ 붙이기)
user_password="\$6\$/VBa6GuBiFiBmi6Q\$yNALrCViVtDDNjyGBsDG7IbnNR0Y/Tda5Uz8ToyxXXpw86XuCVAlhXlIvzy1M8O.DWFB6TRCia0hMuAJiXOZy/"

# LUKS 자동화: yes 로 두면 동일 패스프레이즈로 비대화형 진행(위험)
auto_luks="no"
crypt_password="changeme"

# 홈 자동 언락용 키파일 사용 여부(권장: yes)
home_keyfile="yes"

### 베이스 패키지
pacstrappacs=(
  base linux linux-firmware amd-ucode
  vi nano cryptsetup util-linux e2fsprogs dosfstools
  sudo networkmanager
)

### GUI 패키지(Openbox)
guipacs=(
  openbox obconf obmenu tint2 nitrogen
  pcmanfm lxappearance
  lightdm lightdm-gtk-greeter
  xorg-server xorg-xinit xorg-xrandr xterm
  firefox network-manager-applet
  neofetch mousepad sbctl
  pavucontrol pulseaudio pulseaudio-alsa
  rofi feh thunar thunar-volman gvfs tumbler file-roller geany
)

### ----- 루트 권한 체크 -----
if [[ "$EUID" -ne 0 ]]; then
  echo "이 스크립트는 root로 실행해야 합니다." >&2
  exit 3
fi

### ----- 네트워크/미러 준비(라이브 환경) -----
if ! command -v reflector >/dev/null 2>&1; then
  pacman -Sy --noconfirm reflector
fi
reflector --country GB --age 24 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

### ----- 파티션 작업 -----
echo "[*] 파티션 초기화 및 생성..."
sgdisk -Z "$target"
sgdisk \
  -n1:0:+512M  -t1:ef00 -c1:EFISYSTEM \
  -n2:0:+2G    -t2:8200 -c2:swap \
  -n3:0:+50G   -t3:8304 -c3:root \
  -N4          -t4:8302 -c4:home \
  "$target"

sleep 2; partprobe -s "$target"; sleep 2

### ----- 암호화 -----
echo "[*] 루트 파티션 암호화(LUKS2)..."
if [[ "$auto_luks" == "yes" ]]; then
  printf "%s" "$crypt_password" | cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/root -
  printf "%s" "$crypt_password" | cryptsetup luksOpen   --type luks2 /dev/disk/by-partlabel/root cryptroot -
else
  cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/root
  cryptsetup luksOpen   --type luks2 /dev/disk/by-partlabel/root cryptroot
fi

echo "[*] 홈 파티션 암호화(LUKS2)..."
if [[ "$auto_luks" == "yes" ]]; then
  printf "%s" "$crypt_password" | cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/home -
  printf "%s" "$crypt_password" | cryptsetup luksOpen   --type luks2 /dev/disk/by-partlabel/home  crypthome -
else
  cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/home
  cryptsetup luksOpen   --type luks2 /dev/disk/by-partlabel/home  crypthome
fi

### ----- 파일시스템 생성/마운트 -----
echo "[*] 파일시스템 생성..."
mkfs.vfat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
mkswap -L swap /dev/disk/by-partlabel/swap
mkfs.ext4 -L root /dev/mapper/cryptroot
mkfs.ext4 -L home /dev/mapper/crypthome

echo "[*] 마운트..."
mount /dev/mapper/cryptroot "$rootmnt"
mkdir -p "$rootmnt"/{efi,home}
mount -t vfat /dev/disk/by-partlabel/EFISYSTEM "$rootmnt"/efi
mount /dev/mapper/crypthome "$rootmnt"/home
swapon /dev/disk/by-partlabel/swap

### ----- 베이스 설치 -----
echo "[*] pacstrap..."
pacstrap -K "$rootmnt" "${pacstrappacs[@]}"

### ----- 로케일/키맵/타임존/호스트네임 -----
echo "[*] 환경 설정..."
# locale.gen 주석 해제
sed -i -e "/^#${locale//\//\\/}/s/^#//" "$rootmnt/etc/locale.gen"
# 설정 파일 제거(항상 firstboot/재생성 가능)
rm -f "$rootmnt"/etc/{machine-id,localtime,hostname,shadow,locale.conf}

# systemd-firstboot 비대화형 설정(항상 실행)
systemd-firstboot --root "$rootmnt" \
  --keymap="$keymap" --locale="$locale" \
  --locale-messages="$locale" --timezone="$timezone" \
  --hostname="$hostname" --setup-machine-id \
  --welcome=false

arch-chroot "$rootmnt" locale-gen

### ----- 사용자/기본 보안 -----
echo "[*] 사용자 생성 및 sudo 구성..."
arch-chroot "$rootmnt" useradd -G wheel -m -p "$user_password" "$username"
# wheel NOPASSWD 허용(원래 스크립트 유지)
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' "$rootmnt/etc/sudoers"

# 루트 계정 잠금은 맨 끝에서 수행(부팅 문제 대비)
# arch-chroot "$rootmnt" usermod -L root

### ----- 커널 커맨드라인/HOOKS -----
echo "[*] mkinitcpio 및 커널 커맨드라인 구성..."
# 커널 커맨드라인: LUKS 루트 명시 + root 장치 지정
ROOT_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/root)
cat > "$rootmnt/etc/kernel/cmdline" <<EOF
quiet rw rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot
EOF

# mkinitcpio HOOKS를 명시적으로 설정(시스템드 기반 + sd-encrypt)
sed -i \
  -e 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
  "$rootmnt/etc/mkinitcpio.conf"

### ----- fstab/crypttab -----
echo "[*] fstab 생성..."
genfstab -U "$rootmnt" >> "$rootmnt/etc/fstab"

echo "[*] /etc/crypttab 구성(홈 자동 언락)..."
if [[ "$home_keyfile" == "yes" ]]; then
  arch-chroot "$rootmnt" mkdir -p /etc/cryptsetup-keys.d
  # 임의 키 생성(루트 전용 권한)
  arch-chroot "$rootmnt" bash -c 'dd if=/dev/urandom of=/etc/cryptsetup-keys.d/crypthome.key bs=512 count=8 status=none && chmod 000 /etc/cryptsetup-keys.d/crypthome.key'
  # 홈 LUKS에 키 추가(기존 패스프레이즈 요청)
  arch-chroot "$rootmnt" cryptsetup luksAddKey /dev/disk/by-partlabel/home /etc/cryptsetup-keys.d/crypthome.key
  HOME_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/home)
  cat >> "$rootmnt/etc/crypttab" <<EOF
crypthome UUID=${HOME_UUID} /etc/cryptsetup-keys.d/crypthome.key luks
EOF
else
  HOME_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/home)
  cat >> "$rootmnt/etc/crypttab" <<EOF
crypthome UUID=${HOME_UUID} none luks
EOF
fi

# 홈 마운트가 genfstab에 by-uuid로 들어갔으면 /dev/mapper로 교체(안전용)
sed -i 's#^\([^ ]\+\)[[:space:]]\+/home[[:space:]].*#\/dev\/mapper\/crypthome /home ext4 defaults 0 2#' "$rootmnt/etc/fstab"

### ----- UKI 프리셋/생성 -----
echo "[*] UKI 프리셋 설정..."
# linux.preset 수정: UKI 경로를 ESP(/efi) 하위로 절대경로 지정
# (esp 토큰 대신 절대경로를 사용해 경로 혼선 방지)
sed -i \
  -e '/^#\?ALL_config/s/.*/ALL_config="\/etc\/mkinitcpio.conf"/' \
  -e '/^#\?ALL_kver/s/.*/ALL_kver="\/boot\/vmlinuz-linux"/' \
  "$rootmnt/etc/mkinitcpio.d/linux.preset"

# PRESETS를 default 하나만 사용(원본 의도 유지)
sed -i -e "s/^PRESETS=.*/PRESETS=('default')/" "$rootmnt/etc/mkinitcpio.d/linux.preset" || true

# default_image 대신 default_uki 설정
sed -i -e 's/^default_image=.*$/#default_image=/' "$rootmnt/etc/mkinitcpio.d/linux.preset" || true
if ! grep -q '^default_uki=' "$rootmnt/etc/mkinitcpio.d/linux.preset"; then
  echo 'default_uki="/efi/EFI/Linux/arch-linux.efi"' >> "$rootmnt/etc/mkinitcpio.d/linux.preset"
fi

# UKI 출력 디렉터리 보장
arch-chroot "$rootmnt" mkdir -p /efi/EFI/Linux

# UKI 생성
arch-chroot "$rootmnt" mkinitcpio -p linux

### ----- 부트로더(systemd-boot) + Secure Boot -----
echo "[*] systemd-boot 설치..."
arch-chroot "$rootmnt" bootctl install --esp-path=/efi

echo "[*] Secure Boot 키/서명(SetupMode에서만)..."
# SetupMode=1 이면 sbctl로 키 등록 및 서명 시도
if efivar -d --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-SetupMode >/dev/null 2>&1; then
  if [[ "$(efivar -p --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-SetupMode 2>/dev/null | tr -cd '0-9')" == "1" ]]; then
    arch-chroot "$rootmnt" sbctl create-keys
    arch-chroot "$rootmnt" sbctl enroll-keys -m
    # systemd-boot 바이너리와 UKI 서명
    arch-chroot "$rootmnt" sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
    # 생성된 UKI 서명
    DEFAULT_UKI=$(arch-chroot "$rootmnt" awk -F= '/^default_uki=/{gsub(/"/,"",$2);print $2}' /etc/mkinitcpio.d/linux.preset)
    arch-chroot "$rootmnt" sbctl sign -s "$DEFAULT_UKI"
  else
    echo " - Secure Boot SetupMode가 아님: 키 등록/서명 건너뜀"
  fi
else
  echo " - efivar 가용성 확인 불가 또는 비UEFI: Secure Boot 단계 건너뜀"
fi

### ----- GUI 설치 및 Openbox 설정 -----
echo "[*] Openbox/GUI 패키지 설치..."
arch-chroot "$rootmnt" pacman -Sy --noconfirm --needed "${guipacs[@]}"

echo "[*] Openbox 사용자 설정 배치..."
arch-chroot "$rootmnt" sudo -u "$username" mkdir -p /home/"$username"/.config/openbox
cat > "$rootmnt"/home/"$username"/.config/openbox/autostart << 'EOF'
# Openbox autostart
nitrogen --restore &
tint2 &
nm-applet &
pasystray &
# picom &   # 필요시 주석 해제
EOF

cat > "$rootmnt"/home/"$username"/.config/openbox/menu.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu>
  <menu id="root-menu" label="Openbox 3">
    <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
    <item label="File Manager"><action name="Execute"><command>thunar</command></action></item>
    <item label="Text Editor"><action name="Execute"><command>geany</command></action></item>
    <item label="Web Browser"><action name="Execute"><command>firefox</command></action></item>
    <separator />
    <item label="Reconfigure"><action name="Reconfigure"/></item>
    <item label="Restart"><action name="Restart"/></item>
    <separator />
    <item label="Exit"><action name="Exit"/></item>
  </menu>
</openbox_menu>
EOF

cat > "$rootmnt"/home/"$username"/.xinitrc << 'EOF'
#!/bin/sh
exec openbox-session
EOF
arch-chroot "$rootmnt" chown -R "$username":"$username" /home/"$username"/.config
arch-chroot "$rootmnt" chown "$username":"$username" /home/"$username"/.xinitrc

### ----- 서비스 활성화 -----
echo "[*] 서비스 활성화..."
systemctl --root "$rootmnt" enable systemd-resolved systemd-timesyncd NetworkManager lightdm
systemctl --root "$rootmnt" mask systemd-networkd

### ----- 마무리 -----
echo "[*] 루트 계정 잠금(선택)…"
arch-chroot "$rootmnt" usermod -L root || true

echo "-----------------------------------"
echo "- Install complete. Rebooting.... -"
echo "-----------------------------------"
sleep 5
sync
reboot
