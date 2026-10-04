#!/bin/bash
# Configures the MFuse e2e servers on a Debian 13 VM. Idempotent.
# Reads MFUSE_E2E_* assignments and then the test public key from stdin, so no secret
# appears on a command line. FTPS uses a private CA created here; copy /etc/mfuse-e2e/ca.pem
# to the test machine and set MFUSE_E2E_CA to its path.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

# Values are taken literally, never evaluated: the script runs as root.
PUBKEY=""
while IFS= read -r line; do
  case "$line" in
    MFUSE_E2E_*=*)
      key="${line%%=*}"
      if [[ ! "$key" =~ ^MFUSE_E2E_[A-Z0-9_]+$ ]]; then
        echo "setup-vm.sh: invalid setting name: $key" >&2
        exit 1
      fi
      printf -v "$key" '%s' "${line#*=}"
      ;;
    ssh-ed25519\ *) PUBKEY="$line" ;;
  esac
done
if [ -z "$PUBKEY" ]; then
  echo "setup-vm.sh: no ssh-ed25519 public key on stdin" >&2
  exit 1
fi
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

# --- TLS: a private CA for this VM; the tests trust its certificate only in-process ---
TLS=/etc/mfuse-e2e
install -d -m 755 "$TLS"
if [ ! -f "$TLS/ca.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=MFuse e2e CA" -keyout "$TLS/ca.key" -out "$TLS/ca.pem" 2>/dev/null
fi
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$MFUSE_E2E_HOST" \
  -keyout "$TLS/server.key" -out "$TLS/server.csr" 2>/dev/null
openssl x509 -req -in "$TLS/server.csr" -CA "$TLS/ca.pem" -CAkey "$TLS/ca.key" -CAcreateserial \
  -days 825 -out "$TLS/server.pem" \
  -extfile <(printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$MFUSE_E2E_HOST") 2>/dev/null
chmod 600 "$TLS/ca.key" "$TLS/server.key"

# --- FTP (vsftpd): plain and explicit FTPS on 21, implicit FTPS on 990 ---
# require_ssl_reuse is off: NIOSSL cannot resume the control connection's TLS session on a
# data connection, so servers that insist on it are not supported.
cat > /etc/vsftpd.conf <<EOF
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
ssl_enable=YES
rsa_cert_file=$TLS/server.pem
rsa_private_key_file=$TLS/server.key
force_local_logins_ssl=NO
force_local_data_ssl=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
EOF
sed -e 's/^force_local_logins_ssl=NO/force_local_logins_ssl=YES/' \
    -e 's/^force_local_data_ssl=NO/force_local_data_ssl=YES/' \
    -e 's/^pasv_min_port=40000/pasv_min_port=40101/' \
    -e 's/^pasv_max_port=40100/pasv_max_port=40200/' \
    /etc/vsftpd.conf > /etc/vsftpd-implicit.conf
printf 'listen_port=990\nimplicit_ssl=YES\n' >> /etc/vsftpd-implicit.conf
cat > /etc/systemd/system/vsftpd-implicit.service <<'EOF'
[Unit]
Description=vsftpd, implicit FTPS (MFuse e2e)
After=network-online.target
[Service]
ExecStart=/usr/sbin/vsftpd /etc/vsftpd-implicit.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vsftpd-implicit >/dev/null 2>&1
systemctl restart vsftpd vsftpd-implicit

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

# --- NFSv3 (nfs-kernel-server). MFuse sends from an unprivileged port, so the export it
# mounts needs `insecure`; /srv/nfs-secure lacks it, to check how that refusal is reported.
if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
  apt-get install -y -qq nfs-kernel-server >/dev/null
fi
install -d -o "$U" -g "$U" /srv/nfs /srv/nfs-secure
cat > /etc/exports <<EOF
/srv/nfs        *(rw,sync,insecure,no_subtree_check)
/srv/nfs-secure *(rw,sync,no_subtree_check)
EOF
exportfs -ra
systemctl enable --now nfs-server >/dev/null 2>&1
systemctl restart nfs-server

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
# weed shell's exit status does not reflect command failures, so both steps check the
# bucket listing instead.
bucket_listed() {
  echo "s3.bucket.list" | weed shell -master=127.0.0.1:9333 2>/dev/null | grep -Eq "^[[:space:]]*$MFUSE_E2E_S3_BUCKET([[:space:]]|$)"
}
ready=""
for _ in $(seq 1 30); do
  if echo "s3.bucket.list" | weed shell -master=127.0.0.1:9333 >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
if [ -z "$ready" ]; then
  echo "setup-vm.sh: SeaweedFS did not become ready" >&2
  exit 1
fi
if ! bucket_listed; then
  echo "s3.bucket.create -name $MFUSE_E2E_S3_BUCKET" | weed shell -master=127.0.0.1:9333 >/dev/null 2>&1
  if ! bucket_listed; then
    echo "setup-vm.sh: could not create bucket $MFUSE_E2E_S3_BUCKET" >&2
    exit 1
  fi
fi

sleep 1
for s in ssh vsftpd vsftpd-implicit smbd apache2 nfs-server mfuse-s3; do printf '%-10s %s\n' "$s" "$(systemctl is-active $s)"; done
