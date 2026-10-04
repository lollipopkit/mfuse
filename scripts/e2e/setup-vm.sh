#!/bin/bash
# Configures the MFuse e2e servers on a Debian 13 VM. Idempotent.
# Reads MFUSE_E2E_* assignments and then the test public key from stdin, so no secret
# appears on a command line.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ENV_FILE=$(mktemp); trap 'rm -f "$ENV_FILE"' EXIT
PUBKEY=""
while IFS= read -r line; do
  case "$line" in
    MFUSE_E2E_*=*) echo "$line" >> "$ENV_FILE" ;;
    ssh-ed25519\ *) PUBKEY="$line" ;;
  esac
done
# shellcheck disable=SC1090
. "$ENV_FILE"
U="$MFUSE_E2E_USER"

# --- user (SFTP, FTP, SMB share owner) ---
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
echo "$U:$MFUSE_E2E_PASSWORD" | chpasswd
install -d -o "$U" -g "$U" -m 700 "/home/$U/.ssh"
echo "$PUBKEY" > "/home/$U/.ssh/authorized_keys"
chown "$U:$U" "/home/$U/.ssh/authorized_keys"; chmod 600 "/home/$U/.ssh/authorized_keys"
install -d -o "$U" -g "$U" "/home/$U/files"

# --- SFTP: password and key for the test user only ---
cat > /etc/ssh/sshd_config.d/60-mfuse-e2e.conf <<EOF
Match User $U
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
EOF
systemctl restart ssh

# --- FTP (plain; vsftpd) ---
cat > /etc/vsftpd.conf <<'EOF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pam_service_name=vsftpd
utf8_filesystem=YES
seccomp_sandbox=NO
EOF
systemctl restart vsftpd

# --- SMB (samba) ---
install -d -o "$U" -g "$U" /srv/smb
cat > /etc/samba/smb.conf <<EOF
[global]
   server role = standalone server
   map to guest = never
   server min protocol = SMB2_02
[$MFUSE_E2E_SMB_SHARE]
   path = /srv/smb
   valid users = $U
   read only = no
   create mask = 0644
   directory mask = 0755
EOF
(echo "$MFUSE_E2E_PASSWORD"; echo "$MFUSE_E2E_PASSWORD") | smbpasswd -s -a "$U" >/dev/null
systemctl restart smbd

# --- WebDAV (apache mod_dav, Basic auth) ---
a2enmod -q dav dav_fs auth_basic >/dev/null
install -d -o www-data -g www-data /srv/dav /var/lib/dav
htpasswd -bc /etc/apache2/mfuse-dav.htpasswd "$U" "$MFUSE_E2E_PASSWORD" >/dev/null 2>&1
chown root:www-data /etc/apache2/mfuse-dav.htpasswd; chmod 640 /etc/apache2/mfuse-dav.htpasswd
cat > /etc/apache2/conf-available/mfuse-dav.conf <<EOF
DavLockDB /var/lib/dav/lockdb
Alias $MFUSE_E2E_WEBDAV_PATH /srv/dav
<Directory /srv/dav>
    Dav On
    Options Indexes
    AuthType Basic
    AuthName "MFuse e2e"
    AuthUserFile /etc/apache2/mfuse-dav.htpasswd
    Require valid-user
</Directory>
EOF
a2enconf -q mfuse-dav >/dev/null
systemctl reload apache2

# --- S3 (SeaweedFS; versitygw mishandles encoding-type, see versity/versitygw#1985) ---
if dpkg -s versitygw >/dev/null 2>&1; then apt-get remove -y -qq versitygw >/dev/null; fi
rm -rf /srv/s3
install -d /srv/seaweed
umask_before=$(umask); umask 077
cat > /etc/mfuse-s3.json <<EOF
{"identities":[{"name":"$U","credentials":[{"accessKey":"$MFUSE_E2E_S3_ACCESS_KEY","secretKey":"$MFUSE_E2E_S3_SECRET_KEY"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
umask "$umask_before"
cat > /etc/systemd/system/mfuse-s3.service <<EOF
[Unit]
Description=MFuse e2e S3 (SeaweedFS)
After=network-online.target
[Service]
ExecStart=/usr/local/bin/weed server -dir=/srv/seaweed -ip=127.0.0.1 -ip.bind=0.0.0.0 -volume.max=4 -master.volumeSizeLimitMB=256 -s3 -s3.port=$MFUSE_E2E_S3_PORT -s3.config=/etc/mfuse-s3.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mfuse-s3 >/dev/null 2>&1
systemctl restart mfuse-s3
for _ in $(seq 1 30); do
  echo "s3.bucket.list" | weed shell -master=127.0.0.1:9333 >/dev/null 2>&1 && break
  sleep 2
done
echo "s3.bucket.create -name $MFUSE_E2E_S3_BUCKET" | weed shell -master=127.0.0.1:9333 >/dev/null 2>&1 || true

sleep 1
for s in ssh vsftpd smbd apache2 mfuse-s3; do printf '%-10s %s\n' "$s" "$(systemctl is-active $s)"; done
