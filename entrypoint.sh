#!/bin/sh

set -e

# ---------
# VARIABLES
# ---------

# Set defaults for environment variables

# DIRECTORIES
BASE_DIR="/sftp"
HOME_DIR="/sftp/data"

# UID/GID
SFTP_UID="${MYSSH_SFTP_UID:=$(stat -c "%u" "$BASE_DIR" 2>/dev/null)}" || true
SFTP_GID="${MYSSH_SFTP_GID:=$(stat -c "%g" "$BASE_DIR" 2>/dev/null)}" || true

# FILES
CONF_FILES_DIR="/fileSecrets"
HOST_KEYS_FILE="${MYSSH_HOST_KEYS_FILE:=host_keys.txt}"
USER_KEYS_FILE="${MYSSH_USER_KEYS_FILE:=user_keys.txt}"
USER_PASS_FILE="${MYSSH_USER_PASS_FILE:=user_pass.txt}"

HOST_KEYS="$CONF_FILES_DIR/$HOST_KEYS_FILE"
USER_KEYS="$CONF_FILES_DIR/$USER_KEYS_FILE"
USER_PASS="$CONF_FILES_DIR/$USER_PASS_FILE"

# SSH_PARAMS
SSH_PARAMS="-D -e -p ${MYSSH_SSH_PORT:=22} ${MYSSH_SSH_PARAMS}"

# FIXED VALUES
HOST_KEY_TYPES="dsa ecdsa ed25519 rsa"
AUTH_KEYS_PATH="/etc/ssh/auth_keys"
USER_SHELL_CMD="/usr/bin/mysecureshell"

# ---------
# FUNCTIONS
# ---------

# Private / Auxiliary Functions
# .............................

# Validate HOST_KEYS, USER_PASS, SFTP_UID and SFTP_GID
_check_environment() {
    # Check the ssh server keys ... we don't boot if we don't have them
    if [ ! -f "$HOST_KEYS" ]; then
        cat <<EOF
We need the host keys on the '$HOST_KEYS' file to proceed.

Call this script with the 'host-keys' argument to get a valid mime file and
mount a directory or file to load it.
EOF
        exit 1
    fi
    # Check that we have users ... if we don't we can't continue
    if [ ! -f "$USER_KEYS" ]; then
        cat <<EOF
We need at least a '$USER_KEYS_FILE' file to provision users.

Call this script with the 'users-tar' argument and a list of usernames to
retrieve a tar file with a valid '$USER_PASS_FILE', a
'$USER_KEYS_FILE' and the corresponding pulic and private keys in RSA and
ED25519 formats.
EOF
        exit 1
    fi
    # Check SFTP_UID
    if [ "$SFTP_UID" -eq "0" ]; then
        echo "The 'SFTP_UID' can't be 0, adjust variable or '$BASE_DIR' owner"
        exit 1
    fi
    # Check SFTP_GID
    if [ "$SFTP_GID" -eq "0" ]; then
        echo "The 'SFTP_GID' can't be 0, adjust variable or '$BASE_DIR' group"
        exit 1
    fi
}

# Adjust ssh host keys
_setup_host_keys() {
    opwd="$(pwd)"
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    ret="0"
    reformime <"$HOST_KEYS" || ret="1"
    for kt in $HOST_KEY_TYPES; do
        key="ssh_host_${kt}_key"
        pub="ssh_host_${kt}_key.pub"
        if [ ! -f "$key" ]; then
            echo "Missing '$key' file"
            ret="1"
        fi
        if [ ! -f "$pub" ]; then
            echo "Missing '$pub' file"
            ret="1"
        fi
        if [ "$ret" -ne "0" ]; then
            continue
        fi
        cat "$key" >"/etc/ssh/$key"
        chmod 0600 "/etc/ssh/$key"
        chown root:root "/etc/ssh/$key"
        cat "$pub" >"/etc/ssh/$pub"
        chmod 0600 "/etc/ssh/$pub"
        chown root:root "/etc/ssh/$pub"
    done
    cd "$opwd"
    rm -rf "$tmpdir"
    return "$ret"
}

# Create users
_setup_user_pass() {
    opwd="$(pwd)"
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    ret="0"
    [ -d "$HOME_DIR" ] || mkdir "$HOME_DIR"
    # Make sure the data dir can be managed by the sftp user and disable write
    # permission on the directory to forbid remote sftp users to remove their
    # own root dir (they have already done it)
    chown "$SFTP_UID:$SFTP_GID" "$HOME_DIR"
    chmod 0555 "$HOME_DIR"
    # Create users
    echo "sftp:sftp:$SFTP_UID:$SFTP_GID:::/bin/false" >"newusers.txt"
    sed -n "/^[^#]/ { s/:/ /p }" "$USER_PASS" | while read -r _u _p; do
        echo "$_u:$_p:$SFTP_UID:$SFTP_GID::$HOME_DIR/$_u:$USER_SHELL_CMD"
    done >>"newusers.txt"
    newusers --badnames newusers.txt
    cd "$opwd"
    rm -rf "$tmpdir"
    return "$ret"
}

# Adjust user keys
_setup_user_keys() {
    sed -n "/^[^#]/ { s/:/ /p }" "$USER_KEYS" | while read -r _u _k; do
        echo "$_k" >>"$AUTH_KEYS_PATH/$_u"
    done
}

# Public functions
# ................

# Generate new host keys and export them in mime format
export_host_keys() {
    ssh-keygen -A >/dev/null
    sed -i -e 's/@.*$/@mysecureshell/' /etc/ssh/ssh_host_*_key.pub
    makemime /etc/ssh/ssh_host_*
}

# Generate user passwords and keys, return 1 if no username is received
gen_users_tar() {
    [ "$#" -gt "0" ] || return 1
    opwd="$(pwd)"
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    for u in "$@"; do
        ssh-keygen -q -a 100 -t ed25519 -f "id_ed25519-$u" -C "$u" -N ""
        ssh-keygen -q -a 100 -b 4096 -t rsa -f "id_rsa-$u" -C "$u" -N ""
        # Legacy RSA private key format
        cp -a "id_rsa-$u" "id_rsa-$u.pem"
        ssh-keygen -q -p -m pem -f "id_rsa-$u.pem" -N "" -P "" >/dev/null
        chmod 0600 "id_rsa-$u.pem"
        echo "$u:$(pwgen -s 16 1)" >>"$USER_PASS_FILE"
        echo "$u:$(cat "id_ed25519-$u.pub")" >>"$USER_KEYS_FILE"
        echo "$u:$(cat "id_rsa-$u.pub")" >>"$USER_KEYS_FILE"
    done
    tar cf - "$USER_PASS_FILE" "$USER_KEYS_FILE" id_* 2>/dev/null
    cd "$opwd"
    rm -rf "$tmpdir"
}

exec_sshd() {
    _check_environment
    _setup_host_keys
    _setup_user_pass
    _setup_user_keys
    echo "Running: /usr/sbin/sshd $SSH_PARAMS"
    # shellcheck disable=SC2086
    exec /usr/sbin/sshd -D $SSH_PARAMS
}

# ----
# MAIN
# ----

case "$1" in
"host-keys")
    export_host_keys
    exit 0
    ;;
"users-tar")
    shift
    gen_users_tar "$@"
    exit 0
    ;;
"server") exec_sshd ;;
*) exec "$@" ;;
esac

# vim: ts=2:sw=2:et
