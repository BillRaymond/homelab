#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# create-user.sh — Interactive helper to create a non-root sudo user,
#                  harden SSH, and migrate root SSH keys.
# -----------------------------------------------------------------------------

set -euo pipefail

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -yq zsh

ZSH_BIN="$(command -v zsh || true)"

# Add zsh to /etc/shells if missing
if [[ -n "$ZSH_BIN" && ! $(grep -Fx "$ZSH_BIN" /etc/shells) ]]; then
  echo "$ZSH_BIN" >> /etc/shells
fi

# Ask for username
while true; do
    read -rp "Enter a username you want to login as: " username
    if [[ "$username" =~ ^[a-z][-a-z0-9_]*$ ]]; then
        break
    else
        echo "⚠️  Invalid username. Use lowercase letters, digits, underscores; must start with a letter."
    fi
done

# Read and confirm password
while true; do
    read -rsp "Enter a password for that user: " password1; echo
    read -rsp "Confirm password: "               password2; echo
    if [[ "$password1" == "$password2" && -n "$password1" ]]; then
        break
    else
        echo "⚠️  Passwords do not match. Please try again."
    fi
done

# Create user if not exists
if ! id "$username" &>/dev/null; then
    default_shell="/bin/bash"
    [[ -x "$ZSH_BIN" ]] && default_shell="$ZSH_BIN"

    useradd --create-home --shell "$default_shell" "$username"
    echo "${username}:${password1}" | chpasswd
else
    echo "⚠️  User $username already exists. Continuing setup."
fi

# Ensure docker group exists
if ! getent group docker >/dev/null; then
    groupadd docker
fi

# Add user to groups
usermod -aG sudo "$username"
usermod -aG docker "$username"

# Set up SSH directory
mkdir -p /home/"$username"/.ssh
chmod 700 /home/"$username"/.ssh
cp /root/.ssh/authorized_keys /home/"$username"/.ssh/authorized_keys
chmod 600 /home/"$username"/.ssh/authorized_keys
chown -R "$username":"$username" /home/"$username"/.ssh

# Create .zshrc if zsh is available
if [[ -x "$ZSH_BIN" ]]; then
  cat > /home/"$username"/.zshrc <<'EOF'
# ~/.zshrc – minimal starter file
export HISTFILE=~/.zsh_history
export HISTSIZE=10000
export SAVEHIST=10000
setopt inc_append_history share_history
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f$ '
EOF
  chown "$username":"$username" /home/"$username"/.zshrc
fi

# Harden SSH
SSHCFG='/etc/ssh/sshd_config'
CLOUDINIT='/etc/ssh/sshd_config.d/50-cloud-init.conf'

patch_line() {
  local key=$1
  local value=$2
  if grep -qiE "^\s*#?\s*${key}\s+" "$SSHCFG"; then
    sed -Ei "s|^\s*#?\s*${key}\s+.*|${key} ${value}|I" "$SSHCFG"
  else
    echo "${key} ${value}" >> "$SSHCFG"
  fi
}

patch_line "PasswordAuthentication" "no"
patch_line "PermitRootLogin"        "no"
patch_line "UsePAM"                 "no"

if [[ -f $CLOUDINIT ]]; then
    rm -f "$CLOUDINIT"
fi

/usr/sbin/sshd -t
systemctl restart ssh

echo "✅ User $username created and SSH hardened successfully."

# Copy example config files
cp n8n/example.env n8n/.env
cp watchtower/example.env watchtower/.env
cp caddy/caddyfile/Caddyfile.example caddy/caddyfile/Caddyfile
cp caddy2/Caddyfile.example caddy2/Caddyfile
cp searxng/example.env searxng/.env
cp searxng/config/settings.yml.example searxng/config/settings.yml
cp openwebui/example.env openwebui/.env

cd ~
mv homelab /home/$username/homelab
chown -R $username:$username /home/$username/homelab

mkdir /home/$username/.config
chown -R $username:$username /home/$username/.config

