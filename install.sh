#!/usr/bin/env bash

# (1) 변수 설정 (기존 값 유지)
USERNAME="yourusername"
LOCALE_CONF="ko_KR.UTF-8 UTF-8"
TIMEZONE="Asia/Seoul"
KEYMAP="kr"

EFI_PART="/dev/sda1"
ROOT_PART="/dev/sda2"
HOME_PART="/dev/sda3"

# (2) 디스크 파티션 생성 (예: EFI, 루트, 암호화된 홈)
parted --script $EFI_PART mklabel gpt
parted --script $EFI_PART mkpart primary fat32 1MiB 513MiB
parted --script $EFI_PART set 1 boot on
parted --script $EFI_PART mkpart primary ext4 513MiB 100%

# (3) 파일시스템 생성
mkfs.fat -F32 $EFI_PART
mkfs.ext4 $ROOT_PART

# 홈 파티션 암호화 후 포맷
cryptsetup luksFormat $HOME_PART
cryptsetup open $HOME_PART home-crypt
mkfs.ext4 /dev/mapper/home-crypt

# (4) 마운트
mount $ROOT_PART /mnt
mkdir -p /mnt/efi
mount $EFI_PART /mnt/efi
mkdir -p /mnt/home
mount /dev/mapper/home-crypt /mnt/home

# (5) 기본 시스템 설치 및 fstab 생성
pacstrap /mnt base base-devel linux linux-firmware vim sudo
genfstab -U /mnt >> /mnt/etc/fstab

# (6) chroot로 시스템 구성
arch-chroot /mnt /bin/bash <<EOF
# (6.1) 로케일 및 시간대 설정
echo "$LOCALE_CONF" > /etc/locale.gen
locale-gen
echo "LANG=$(echo $LOCALE_CONF | cut -d' ' -f1)" > /etc/locale.conf
export LANG=$(echo $LOCALE_CONF | cut -d' ' -f1)

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# (6.2) 호스트네임과 hosts
echo "archlinux" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
HOSTS

# (6.3) 루트 비밀번호 설정
echo "root:yourpassword" | chpasswd

# (6.4) 사용자 계정 생성 및 권한 부여
useradd -m -G wheel $USERNAME
echo "$USERNAME:yourpassword" | chpasswd
sed -i 's/^# %wheel/%wheel/' /etc/sudoers

# (6.5) vconsole 설정 (키보드 레이아웃)
cat > /etc/vconsole.conf <<VC
KEYMAP=$KEYMAP
FONT=latarcyrheb-sun32
VC

# (6.6) systemd-firstboot 준비
# 기존 머신 ID 등 제거
rm -f /etc/machine-id /etc/hostname /etc/localtime /etc/locale.conf /etc/shadow
# 첫 부팅 시 시스템 설정 묻기 위한 systemd-firstboot 서비스 드롭인 파일
mkdir -p /etc/systemd/system/systemd-firstboot.service.d
cat > /etc/systemd/system/systemd-firstboot.service.d/install.conf <<FIRSTBOOT
[Service]
ExecStart=
ExecStart=/usr/bin/systemd-firstboot --prompt

[Install]
WantedBy=sysinit.target
FIRSTBOOT
systemctl enable systemd-firstboot.service

# (6.7) /home 파티션 자동 언락 설정 (/etc/crypttab)
mkdir -p /etc/cryptsetup-keys.d
# 랜덤 키파일 생성 및 권한 설정
dd bs=512 count=4 if=/dev/urandom of=/etc/cryptsetup-keys.d/home.key
chmod 000 /etc/cryptsetup-keys.d/home.key
# LUKS 파티션에 키 추가
echo -n "Enter existing passphrase for /home partition: "
cryptsetup luksAddKey $HOME_PART /etc/cryptsetup-keys.d/home.key
# UUID를 이용해 crypttab에 등록 (키파일 사용)
HOME_UUID=\$(blkid -s UUID -o value $HOME_PART)
echo "home-crypt UUID=\$HOME_UUID /etc/cryptsetup-keys.d/home.key" >> /etc/crypttab
# /home 마운트 정보 fstab에 등록
echo "/dev/mapper/home-crypt /home ext4 defaults 0 2" >> /etc/fstab

# (6.8) systemd-boot 설치
pacman --noconfirm -S systemd-boot
bootctl --esp-path=/efi install

# (6.9) mkinitcpio preset 수정 (UKI 생성 설정)
mkdir -p /efi/EFI/Linux
cat > /etc/mkinitcpio.d/linux.preset <<PRESET
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')

default_uki="esp/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="esp/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
PRESET

# (6.10) Secure Boot용 sbctl 설정 및 부트로더 서명
pacman --noconfirm -S sbctl
sbctl create-keys
sbctl enroll-keys -m
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
# systemd-boot 재설치/업데이트하여 서명된 EFI 적용
bootctl --esp-path=/efi install
bootctl --esp-path=/efi update

EOF

echo "설치가 완료되었습니다. 시스템을 재부팅하세요."
