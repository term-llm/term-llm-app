#!/bin/sh
# CODE ONLY. Sam must review and run explicitly on the downloads server.
# Usage: sudo sh setup-mac-downloads.sh /root/reviewed-mac-upload-key.pub
# Never run this as part of app CI. It does not generate keys or fetch secrets.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root after review' >&2; exit 1; }
[ "$#" = 1 ] || { echo 'Pass a reviewed Ed25519 PUBLIC SSH key file' >&2; exit 1; }
key=$(cat "$1")
# Exactly one ordinary Ed25519 public key; reject options/multiline input.
case "$key" in
  *'
'*) echo 'Expected one public key line' >&2; exit 1;;
esac
printf '%s\n' "$key" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [A-Za-z0-9@._ -]+)?$' || {
  echo 'Expected an ssh-ed25519 public key without authorized_keys options' >&2; exit 1;
}
command -v rrsync >/dev/null || { echo 'Install rsync (including /usr/bin/rrsync) first' >&2; exit 1; }
[ -x /usr/bin/rrsync ] || { echo 'Review the local rrsync path first' >&2; exit 1; }
user=term-llm-updates
home=/var/lib/term-llm-updates
dest=/var/www/term-llm-downloads/mac
if id "$user" >/dev/null 2>&1; then
  echo "Account $user already exists; inspect it rather than altering it automatically" >&2
  exit 1
fi
# Shell is necessary for sshd forced commands; no password login or forwarding.
useradd --system --user-group --home-dir "$home" --shell /bin/sh "$user"
passwd -l "$user"
install -d -o root -g root -m 0755 "$home" "$home/.ssh" /var/www/term-llm-downloads
install -d -o "$user" -g "$user" -m 0755 "$dest"
printf 'restrict,command="/usr/bin/rrsync -wo -no-del %s" %s\n' "$dest" "$key" > "$home/.ssh/authorized_keys"
chown root:root "$home/.ssh/authorized_keys"
chmod 0644 "$home/.ssh/authorized_keys"
# Root-owned home/key files cannot be replaced through the restricted rsync root.
cat > /etc/ssh/sshd_config.d/term-llm-updates.conf <<'SSH'
Match User term-llm-updates
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
    PermitTTY no
    X11Forwarding no
    ForceCommand /usr/bin/rrsync -wo -no-del /var/www/term-llm-downloads/mac
Match all
SSH
sshd -t
echo 'Created restricted account. Review effective sshd configuration, then reload SSH yourself.'
echo 'Install docs/deployment/mac.conf, nginx -t, then reload nginx yourself.'
echo 'Verify restrictions and pin the server host key before allowing CI publication.'
