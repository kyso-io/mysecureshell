#!/bin/sh

set -e

# VARIABLES
IMG_NAME="registry.kyso.io/docker/mysecureshell/main"
CNAME="myssh"

# RUNTIME VARIABLES
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
WORK_DIR="$(readlink -f "$SCRIPT_DIR/..")"

BASE_DIR="/sftp"
CONF_DIR="/fileSecrets"

HOST_KEYS="host_keys.txt"
USER_KEYS="user_keys.txt"
USER_PASS="user_pass.txt"

SRV_BASE_DIR="${WORK_DIR}${BASE_DIR}"
SRV_CONF_DIR="${WORK_DIR}${CONF_DIR}"
SRV_HOST_KEYS="${SRV_CONF_DIR}/${HOST_KEYS}"
SRV_USER_KEYS="${SRV_CONF_DIR}/${USER_KEYS}"
SRV_USER_PASS="${SRV_CONF_DIR}/${USER_PASS}"

MYSSH_PORT="${MYSSH_PORT:=2022}"

# FUNCTIONS
_build() {
  cd "$WORK_DIR"
  docker build --build-arg "$(cat .build-args)" -t "$IMG_NAME" .
}

_pull() {
  # pull latest image
  docker pull "$IMG_NAME"
  # remove dangling images
  for _img in $(docker images --filter "dangling=true" -q "$IMG_NAME"); do
    docker rmi "${_img}" || true
  done
}

_init() {
  if [ ! -d "$SRV_BASE_DIR" ]; then
    mkdir "$SRV_BASE_DIR"
  fi
  if [ ! -d "$SRV_CONF_DIR" ]; then
    mkdir "$SRV_CONF_DIR"
  fi
  [ "$#" -eq "0" ] && _users="$(id -un)" || _users="$*"
  # shellcheck disable=SC2086
  docker run --rm \
    --env MYSSH_SFTP_UID="${MYSSH_SFTP_UID}" \
    --env MYSSH_SFTP_GID="${MYSSH_SFTP_GID}" \
    --env MYSSH_HOST_KEYS="${HOST_KEYS}" \
    --env MYSSH_USER_KEYS="${USER_KEYS}" \
    --env MYSSH_USER_PASS="${USER_PASS}" \
    --volume "$SRV_BASE_DIR:$BASE_DIR:rw,z" \
    --volume "$SRV_CONF_DIR:$CONF_DIR:rw,z" \
    "$IMG_NAME" init $_users
}

_run() {
  docker run --rm -ti \
    --cap-add "IPC_OWNER" \
    --publish "$MYSSH_PORT:22" \
    --env MYSSH_SFTP_UID="${MYSSH_SFTP_UID}" \
    --env MYSSH_SFTP_GID="${MYSSH_SFTP_GID}" \
    --env MYSSH_HOST_KEYS="${HOST_KEYS}" \
    --env MYSSH_USER_KEYS="${USER_KEYS}" \
    --env MYSSH_USER_PASS="${USER_PASS}" \
    --volume "$SRV_BASE_DIR:$BASE_DIR:rw,z" \
    --volume "$SRV_CONF_DIR:$CONF_DIR:rw,z" \
    --name "$CNAME" \
    "$IMG_NAME" "$@"
}

_run_daemon() {
  if [ ! -f "$SRV_HOST_KEYS" ] || [ ! -f "$SRV_USER_KEYS" ] ||
    [ ! -f "$SRV_USER_PASS" ]; then
    echo "Required files missing, call '$0 init USERS_LIST' to create them"
    return 1
  fi
  docker run --detach \
    --cap-add "IPC_OWNER" \
    --publish "$MYSSH_PORT:22" \
    --env MYSSH_SFTP_UID="${MYSSH_SFTP_UID}" \
    --env MYSSH_SFTP_GID="${MYSSH_SFTP_GID}" \
    --env MYSSH_HOST_KEYS="${HOST_KEYS}" \
    --env MYSSH_USER_KEYS="${USER_KEYS}" \
    --env MYSSH_USER_PASS="${USER_PASS}" \
    --volume "$SRV_BASE_DIR:$BASE_DIR:rw,z" \
    --volume "$SRV_CONF_DIR:$CONF_DIR:rw,z" \
    --restart always \
    --name "$CNAME" \
    "$IMG_NAME" "$@"
}

_logs() {
  docker logs "${CNAME}" "$@"
}

_ps_status() {
  docker ps -a -f name="${CNAME}" --format '{{.Status}}' 2>/dev/null || true
}

_inspect_status() {
  docker inspect ${CNAME} -f "{{.State.Status}}" 2>/dev/null || true
}

_status() {
  _st="$(_ps_status)"
  if [ -z "$_st" ]; then
    echo "The container '${CNAME}' does not exist"
    exit 1
  else
    echo "$_st"
  fi
}

_start() {
  _st="$(_inspect_status)"
  if [ -z "$_st" ]; then
    _run_daemon "$@"
  elif [ "$_st" != "running" ] && [ "$_st" != "restarting" ]; then
    docker start "${CNAME}"
  fi
}

_stop() {
  _st="$(_inspect_status)"
  if [ "$_st" = "running" ] || [ "$_st" = "restarting" ]; then
    docker stop "${CNAME}"
  fi
}

_restart() {
  _stop
  _start "$@"
}

_rm() {
  _st="$(_inspect_status)"
  if [ -n "$_st" ]; then
    _stop
    docker rm "${CNAME}"
  fi
}

_exec() {
  docker exec -ti "${CNAME}" "$@"
}

_usage() {
  cat <<EOF
Usage: $0 {start|stop|status|restart|rm|run|logs|exec|build|pull|init}
EOF
  exit 0
}

# ====
# MAIN
# ====
case "$1" in
start)
  shift
  _start "$@"
  ;;
stop) _stop ;;
status) _status ;;
restart)
  shift
  _restart "$@"
  ;;
run)
  shift
  # run the container removing the default ARGS if no argument is passed
  if [ "$*" ]; then
    _run "$@"
  else
    _run ""
  fi
  ;;
rm) _rm ;;
logs)
  shift
  _logs "$@"
  ;;
exec)
  shift
  _exec "$@"
  ;;
build) _build ;;
pull) _pull ;;
init)
  shift
  _init "$@"
  ;;
*) _usage ;;
esac

# vim: ts=2:sw=2:et
