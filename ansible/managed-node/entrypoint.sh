#!/bin/sh
set -eu
install -d -m 0755 /run/sshd
install -d -m 0700 -o ansible -g ansible /home/ansible/.ssh
install -m 0600 -o ansible -g ansible /run/bootstrap/authorized_keys /home/ansible/.ssh/authorized_keys
ssh-keygen -A >/dev/null
cat > /etc/ssh/sshd_config.d/00-hio.conf <<'EOF'
StrictModes yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
EOF
/usr/sbin/sshd -t
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
