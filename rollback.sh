#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="awg-block-ru"
TABLE_NAME="awg_ru_block"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
RUNTIME_DIR="/run/${APP_NAME}"
LOCK_FILE="/run/${APP_NAME}.lock"
UNIT_DIR="/etc/systemd/system"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/${APP_NAME}-limits.conf"
DOCKER_CONFIG="/etc/docker/daemon.json"

# Stop activation sources before stopping the services they may start.
UNITS=(
	"${APP_NAME}-refresh.timer"
	"${APP_NAME}-housekeeping.timer"
	"${APP_NAME}-watch.service"
	"${APP_NAME}-refresh.service"
	"${APP_NAME}-housekeeping.service"
)
UNIT_LINKS=(
	"timers.target.wants/${APP_NAME}-refresh.timer"
	"timers.target.wants/${APP_NAME}-housekeeping.timer"
	"multi-user.target.wants/${APP_NAME}-watch.service"
	"multi-user.target.wants/${APP_NAME}-housekeeping.service"
)

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
}

exists() {
	[[ -e "$1" || -L "$1" ]]
}

docker_local() {
	# Container PIDs must refer to this host, not to a remote Docker context.
	docker --host unix:///var/run/docker.sock "$@"
}

container_pid() {
	docker_local inspect -f '{{.State.Pid}}' "$1"
}

visit_table() (
	local action="$1" name="$2"
	local pid tables

	pid="$(container_pid "$name")" || die "Could not inspect ${name}"
	[[ "$pid" =~ ^[0-9]+$ ]] || die "Invalid container PID for ${name}"
	# A stopped container has no running network namespace to clean.
	[[ "$pid" != 0 ]] || return 0
	exec 8< "/proc/${pid}/ns/net" || die "Could not open the network namespace of ${name}; retry rollback"
	[[ "$(container_pid "$name")" == "$pid" ]] || die "${name} restarted; retry rollback"

	tables="$(nsenter --net=/proc/self/fd/8 nft list tables)" ||
		die "Could not list nftables tables in ${name}"
	if ! grep -Fxq "table inet ${TABLE_NAME}" <<< "$tables"; then
		return 0
	fi

	if [[ "$action" == "remove" ]]; then
		nsenter --net=/proc/self/fd/8 nft delete table inet "$TABLE_NAME" ||
			die "Could not remove the blocking table in ${name}"
		printf 'Removed table inet %s in %s\n' "$TABLE_NAME" "$name"
	else
		printf 'Remove table inet %s in %s\n' "$TABLE_NAME" "$name"
	fi
)

visit_tables() {
	local action="$1"
	local names name

	names="$(docker_local ps --format '{{.Names}}')" ||
		die "Could not list running Docker containers; no reliable rollback is possible"
	while IFS= read -r name; do
		if [[ "$name" == amnezia* ]]; then
			visit_table "$action" "$name" || return 1
		fi
	done <<< "$names"
}

check_legacy_docker_config() {
	# This option is only for hosts where the file did not exist originally.
	# Do not guess if anything besides the exact legacy config is present.
	[[ -f "$DOCKER_CONFIG" && ! -L "$DOCKER_CONFIG" ]] ||
		die "Refusing to remove Docker configuration: not a regular file"
	python3 - "$DOCKER_CONFIG" <<'PY' ||
import json
import sys

expected = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
}


def reject_duplicates(items):
    result = dict(items)
    if len(result) != len(items):
        raise ValueError("duplicate JSON keys")
    return result


with open(sys.argv[1], encoding="utf-8") as file:
    sys.exit(json.load(file, object_pairs_hook=reject_duplicates) != expected)
PY
		die "Refusing to remove Docker configuration: it differs from the exact legacy settings"
}

usage() {
	cat <<EOF
Usage: sudo bash $0 [--dry-run] [--docker-config-was-absent]

Remove awg-block-ru rules, services, installed script, cache and legacy
journald drop-in. Blocking of Russian IP networks will stop.
Run with --dry-run first. Do not run apply or install concurrently.

Docker and Amnezia are not restarted. The Docker configuration is left alone
unless --docker-config-was-absent is specified and the file contains only
the exact logging settings set by the original installer.
Existing containers retain their own logging settings.
Packages and data already deleted by prior housekeeping are not restored.
EOF
}

main() {
	local dry_run=false remove_docker_config=false
	local table_plan unit path unit_changes=false active_state
	local -a unit_paths=()
	local -a units_to_stop=()
	local -a remove_paths=()

	while (( $# > 0 )); do
		case "$1" in
			--dry-run) dry_run=true ;;
			--docker-config-was-absent) remove_docker_config=true ;;
			-h|--help) usage; return 0 ;;
			*) die "Unknown option: $1" ;;
		esac
		shift
	done
	require_root
	for path in docker flock nft nsenter systemctl; do
		command -v "$path" >/dev/null || die "Required command not found: ${path}"
	done

	if "$remove_docker_config" && exists "$DOCKER_CONFIG"; then
		command -v python3 >/dev/null || die "python3 is needed to validate Docker configuration"
		check_legacy_docker_config
		remove_paths+=("$DOCKER_CONFIG")
	elif exists "$DOCKER_CONFIG"; then
		printf 'Leaving %s unchanged (original contents unknown)\n' "$DOCKER_CONFIG"
	fi

	table_plan="$(visit_tables plan)" || die "Aborted before changing rules or services"
	for unit in "${UNITS[@]}"; do
		path="${UNIT_DIR}/${unit}"
		active_state="$(systemctl show --property=ActiveState --value "$unit")" ||
			die "Could not determine the state of ${unit}"
		if exists "$path"; then
			unit_paths+=("$path")
			units_to_stop+=("$unit")
		elif [[ "$active_state" != "inactive" && "$active_state" != "failed" ]]; then
			units_to_stop+=("$unit")
		fi
	done
	for path in "${UNIT_LINKS[@]}"; do
		if exists "${UNIT_DIR}/${path}"; then
			unit_paths+=("${UNIT_DIR}/${path}")
		fi
	done
	for path in "$JOURNALD_DROPIN" "$INSTALL_PATH" "$STATE_DIR" "$RUNTIME_DIR" "$LOCK_FILE"; do
		if exists "$path"; then
			remove_paths+=("$path")
		fi
	done

	if [[ -z "$table_plan" && ${#units_to_stop[@]} -eq 0 &&
		${#unit_paths[@]} -eq 0 && ${#remove_paths[@]} -eq 0 ]]; then
		printf '%s is already absent\n' "$APP_NAME"
		return 0
	fi

	if "$dry_run"; then
		printf '%s\n' 'Dry run; no changes made.'
		for unit in ${units_to_stop[@]+"${units_to_stop[@]}"}; do printf 'Stop %s\n' "$unit"; done
		if [[ -n "$table_plan" ]]; then printf '%s\n' "$table_plan"; fi
		for path in ${unit_paths[@]+"${unit_paths[@]}"} ${remove_paths[@]+"${remove_paths[@]}"}; do
			printf 'Remove %s\n' "$path"
		done
		if exists "$JOURNALD_DROPIN"; then printf '%s\n' 'Restart systemd-journald'; fi
		return 0
	fi

	for unit in ${units_to_stop[@]+"${units_to_stop[@]}"}; do
		systemctl stop "$unit"
	done
	exec 9>"$LOCK_FILE"
	flock -w 60 9 || die "Could not acquire ${LOCK_FILE}"
	visit_tables remove

	for path in ${unit_paths[@]+"${unit_paths[@]}"}; do
		rm -f -- "$path"
		unit_changes=true
	done
	if "$unit_changes"; then systemctl daemon-reload; fi
	if exists "$JOURNALD_DROPIN"; then
		rm -f -- "$JOURNALD_DROPIN"
		systemctl restart systemd-journald
	fi
	if "$remove_docker_config" && exists "$DOCKER_CONFIG"; then
		check_legacy_docker_config
		rm -- "$DOCKER_CONFIG"
	fi
	rm -f -- "$INSTALL_PATH"
	rm -rf -- "$STATE_DIR" "$RUNTIME_DIR"
	rm -f -- "$LOCK_FILE"
	printf 'Removed %s rules and installation; Docker and Amnezia were not restarted\n' "$APP_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
