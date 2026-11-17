#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="awg-block-ru"

INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
RUNTIME_DIR="/run/${APP_NAME}"

RU4_FILE="${STATE_DIR}/ru4.zone"
RU6_FILE="${STATE_DIR}/ru6.zone"
RULESET_FILE="${STATE_DIR}/rules.nft"

LOCK_FILE="/run/${APP_NAME}.lock"

TABLE_NAME="awg_ru_block"
AWG_IFACE="awg0"
PRIMARY_CONTAINER="amnezia-awg2"

RU4_URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
RU6_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated/ru-aggregated.zone"

WATCH_UNIT="${APP_NAME}-watch.service"
REFRESH_UNIT="${APP_NAME}-refresh.service"
TIMER_UNIT="${APP_NAME}-refresh.timer"

LEGACY_HOUSEKEEPING_UNIT="${APP_NAME}-housekeeping.service"
LEGACY_HOUSEKEEPING_TIMER="${APP_NAME}-housekeeping.timer"

WATCH_INTERVAL_SECONDS=5
LOCK_TIMEOUT_SECONDS=60

TEMP_FILES=()


log() {
	printf '[%s] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$*"
}


warn() {
	printf '[%s] WARNING: %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$*" >&2
}


die() {
	printf '[%s] ERROR: %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$*" >&2

	exit 1
}


cleanup_temp_files() {
	local file

	for file in "${TEMP_FILES[@]}"; do
		rm -f "$file" 2>/dev/null || true
	done
}


on_error() {
	local rc="$1"
	local line="$2"
	local cmd="$3"

	printf '\n[%s] ERROR\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" >&2

	printf 'Exit code: %s\n' "$rc" >&2
	printf 'Line:      %s\n' "$line" >&2
	printf 'Command:   %s\n\n' "$cmd" >&2

	exit "$rc"
}


trap cleanup_temp_files EXIT
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR


register_temp_file() {
	TEMP_FILES+=("$1")
}


require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		die "Run this script as root: sudo bash $0"
	fi
}


command_exists() {
	command -v "$1" >/dev/null 2>&1
}


check_os() {
	if [[ ! -r /etc/os-release ]]; then
		die "/etc/os-release not found"
	fi

	# shellcheck disable=SC1091
	. /etc/os-release

	log "Detected OS: ${PRETTY_NAME:-unknown}"

	if [[ "${ID:-}" != "ubuntu" ]]; then
		warn "Ubuntu was expected, detected: ${ID:-unknown}"
	fi

	case "${VERSION_ID:-}" in
		22.04)
			;;
		24.04)
			warn "Script was primarily prepared for Ubuntu 22.04, but 24.04 is supported"
			;;
		*)
			warn "Ubuntu ${VERSION_ID:-unknown} has not been explicitly tested"
			;;
	esac
}


install_dependencies() {
	local missing=false
	local cmd

	for cmd in curl nft ip nsenter flock; do
		if ! command_exists "$cmd"; then
			missing=true
			break
		fi
	done

	if [[ "$missing" == false ]]; then
		return
	fi

	command_exists apt-get ||
		die "apt-get not found"

	log "Installing required packages"

	export DEBIAN_FRONTEND=noninteractive

	apt-get update

	apt-get install -y \
		--no-install-recommends \
		ca-certificates \
		curl \
		nftables \
		iproute2 \
		util-linux
}


check_docker() {
	command_exists docker ||
		die "docker command not found"

	if ! docker info >/dev/null 2>&1; then
		die "Docker daemon is unavailable. Check: systemctl status docker"
	fi
}


prepare_directories() {
	mkdir -p "$STATE_DIR"
	mkdir -p "$RUNTIME_DIR"

	chmod 0755 "$STATE_DIR"
	chmod 0700 "$RUNTIME_DIR"
}


check_free_space() {
	local available_kb

	prepare_directories

	available_kb="$(
		df -Pk "$STATE_DIR" |
			awk 'NR == 2 { print $4 }'
	)"

	if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
		die "Could not determine available disk space"
	fi

	if (( available_kb < 10240 )); then
		die "Less than 10 MiB free on filesystem containing ${STATE_DIR}"
	fi
}


acquire_lock() {
	exec 9>"$LOCK_FILE"

	if ! flock -w "$LOCK_TIMEOUT_SECONDS" 9; then
		die "Could not acquire lock ${LOCK_FILE} within ${LOCK_TIMEOUT_SECONDS}s"
	fi
}


container_pid() {
	local container="$1"
	local pid

	pid="$(
		docker inspect \
			-f '{{.State.Pid}}' \
			"$container" \
			2>/dev/null ||
			true
	)"

	if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ "$pid" -le 0 ]]; then
		return 1
	fi

	printf '%s\n' "$pid"
}


find_awg_container() {
	local pid
	local container

	if pid="$(container_pid "$PRIMARY_CONTAINER")"; then
		if nsenter \
			-t "$pid" \
			-n \
			ip link show "$AWG_IFACE" \
			>/dev/null 2>&1; then

			printf '%s\n' "$PRIMARY_CONTAINER"
			return 0
		fi
	fi

	while IFS= read -r container; do
		[[ -n "$container" ]] || continue

		case "$container" in
			amnezia*)
				;;
			*)
				continue
				;;
		esac

		if ! pid="$(container_pid "$container")"; then
			continue
		fi

		if nsenter \
			-t "$pid" \
			-n \
			ip link show "$AWG_IFACE" \
			>/dev/null 2>&1; then

			printf '%s\n' "$container"
			return 0
		fi

	done < <(
		docker ps \
			--format '{{.Names}}'
	)

	return 1
}


validate_ipv4_file() {
	local file="$1"
	local count

	count="$(
		grep -cve '^[[:space:]]*$' "$file" ||
			true
	)"

	if [[ "$count" -lt 500 ]]; then
		warn "IPv4 list looks too small: ${count} entries"
		return 1
	fi

	if grep \
		-Evm1 \
		'^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$' \
		"$file" \
		>/dev/null; then

		warn "IPv4 list contains unexpected data"
		return 1
	fi

	return 0
}


validate_ipv6_file() {
	local file="$1"
	local count

	count="$(
		grep -cve '^[[:space:]]*$' "$file" ||
			true
	)"

	if [[ "$count" -lt 100 ]]; then
		warn "IPv6 list looks too small: ${count} entries"
		return 1
	fi

	if grep \
		-Evm1 \
		'^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' \
		"$file" \
		>/dev/null; then

		warn "IPv6 list contains unexpected data"
		return 1
	fi

	return 0
}


lists_exist() {
	[[ \
		-s "$RU4_FILE" &&
		-s "$RU6_FILE"
	]]
}


download_lists() {
	local tmp4
	local tmp6

	prepare_directories

	tmp4="$(mktemp "${RUNTIME_DIR}/ru4.XXXXXX")"
	tmp6="$(mktemp "${RUNTIME_DIR}/ru6.XXXXXX")"

	register_temp_file "$tmp4"
	register_temp_file "$tmp6"

	log "Downloading RU IPv4 list from IPdeny"

	if ! curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--connect-timeout 15 \
		--max-time 60 \
		"$RU4_URL" \
		-o "$tmp4"; then

		warn "Failed to download IPv4 list"
		return 1
	fi

	log "Downloading RU IPv6 list from IPdeny"

	if ! curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--connect-timeout 15 \
		--max-time 60 \
		"$RU6_URL" \
		-o "$tmp6"; then

		warn "Failed to download IPv6 list"
		return 1
	fi

	sed -i 's/\r$//' "$tmp4"
	sed -i 's/\r$//' "$tmp6"

	if ! validate_ipv4_file "$tmp4"; then
		return 1
	fi

	if ! validate_ipv6_file "$tmp6"; then
		return 1
	fi

	install \
		-m 0644 \
		"$tmp4" \
		"${RU4_FILE}.new"

	install \
		-m 0644 \
		"$tmp6" \
		"${RU6_FILE}.new"

	mv \
		"${RU4_FILE}.new" \
		"$RU4_FILE"

	mv \
		"${RU6_FILE}.new" \
		"$RU6_FILE"

	log "Lists updated: IPv4=$(wc -l < "$RU4_FILE"), IPv6=$(wc -l < "$RU6_FILE")"

	return 0
}


build_ruleset() {
	local tmp_ruleset

	validate_ipv4_file "$RU4_FILE" ||
		die "Cached IPv4 list is invalid"

	validate_ipv6_file "$RU6_FILE" ||
		die "Cached IPv6 list is invalid"

	tmp_ruleset="${RULESET_FILE}.tmp.$$"

	register_temp_file "$tmp_ruleset"

	{
		printf 'table inet %s {\n' "$TABLE_NAME"

		printf '\tset ru4 {\n'
		printf '\t\ttype ipv4_addr\n'
		printf '\t\tflags interval\n'
		printf '\t\telements = { '

		awk '
			NF {
				if (n++) {
					printf ", "
				}

				printf "%s", $1
			}

			END {
				printf " }\n"
			}
		' "$RU4_FILE"

		printf '\t}\n'

		printf '\n'

		printf '\tset ru6 {\n'
		printf '\t\ttype ipv6_addr\n'
		printf '\t\tflags interval\n'
		printf '\t\telements = { '

		awk '
			NF {
				if (n++) {
					printf ", "
				}

				printf "%s", $1
			}

			END {
				printf " }\n"
			}
		' "$RU6_FILE"

		printf '\t}\n'

		printf '\n'

		printf '\tchain forward {\n'
		printf '\t\ttype filter hook forward priority -100; policy accept;\n'

		printf \
			'\t\tiifname "%s" ip daddr @ru4 counter reject\n' \
			"$AWG_IFACE"

		printf \
			'\t\tiifname "%s" ip6 daddr @ru6 counter reject\n' \
			"$AWG_IFACE"

		printf '\t}\n'

		printf '}\n'
	} > "$tmp_ruleset"

	mv \
		"$tmp_ruleset" \
		"$RULESET_FILE"
}


table_active() {
	local pid="$1"

	nsenter \
		-t "$pid" \
		-n \
		nft list table inet "$TABLE_NAME" \
		>/dev/null 2>&1
}


chain_active() {
	local pid="$1"

	nsenter \
		-t "$pid" \
		-n \
		nft list chain inet "$TABLE_NAME" forward \
		>/dev/null 2>&1
}


create_atomic_batch() {
	local pid="$1"
	local batch_file="$2"

	if table_active "$pid"; then
		{
			printf 'delete table inet %s\n' "$TABLE_NAME"
			cat "$RULESET_FILE"
		} > "$batch_file"
	else
		cp \
			"$RULESET_FILE" \
			"$batch_file"
	fi
}


apply_rules() {
	local refresh="${1:-false}"
	local container
	local pid
	local batch_file

	require_root
	prepare_directories
	check_free_space
	acquire_lock
	check_docker

	if [[ "$refresh" == true ]]; then
		if ! download_lists; then
			if lists_exist; then
				warn "Could not refresh lists; keeping cached lists"
			else
				die "Could not download RU lists and no cached copy exists"
			fi
		fi
	elif ! lists_exist; then
		if ! download_lists; then
			die "RU lists are missing and download failed"
		fi
	fi

	container="$(find_awg_container)" ||
		die "Running AmneziaWG container with interface ${AWG_IFACE} was not found"

	pid="$(container_pid "$container")" ||
		die "Could not obtain PID for container ${container}"

	log "Using container=${container}, pid=${pid}, interface=${AWG_IFACE}"

	build_ruleset

	batch_file="$(
		mktemp \
			"${RUNTIME_DIR}/apply.XXXXXX"
	)"

	register_temp_file "$batch_file"

	create_atomic_batch \
		"$pid" \
		"$batch_file"

	#
	# Проверяем полный batch до применения.
	#
	if ! nsenter \
		-t "$pid" \
		-n \
		nft \
		--check \
		--file "$batch_file"; then

		die "nftables validation failed; current rules were NOT changed"
	fi

	#
	# Весь batch выполняется одной nftables-транзакцией:
	#
	#	delete old table
	#	create new table
	#
	# Поэтому окна без firewall между delete/create нет.
	#
	if ! nsenter \
		-t "$pid" \
		-n \
		nft \
		--file "$batch_file"; then

		die "Failed to apply nftables rules"
	fi

	if ! table_active "$pid"; then
		die "Blocking table ${TABLE_NAME} was not created"
	fi

	if ! chain_active "$pid"; then
		die "Blocking chain ${TABLE_NAME}/forward was not created"
	fi

	log "RU IPv4/IPv6 blocking is active for traffic entering via ${AWG_IFACE}"
}


watch_mode() {
	local container=""
	local pid=""
	local last_pid=""
	local missing_logged=false

	require_root
	prepare_directories
	check_docker

	log "Starting AmneziaWG firewall watcher"

	while true; do
		container="$(
			find_awg_container 2>/dev/null ||
				true
		)"

		if [[ -z "$container" ]]; then
			if [[ "$missing_logged" == false ]]; then
				warn "AmneziaWG container with ${AWG_IFACE} is not currently available"
				missing_logged=true
			fi

			last_pid=""

			sleep "$WATCH_INTERVAL_SECONDS"
			continue
		fi

		missing_logged=false

		pid="$(
			container_pid "$container" 2>/dev/null ||
				true
		)"

		if [[ -z "$pid" ]]; then
			sleep "$WATCH_INTERVAL_SECONDS"
			continue
		fi

		#
		# Новый PID означает, что контейнер/network namespace
		# был пересоздан.
		#
		if [[ "$pid" != "$last_pid" ]]; then
			log "Detected AmneziaWG namespace: container=${container}, pid=${pid}"

			if table_active "$pid" && chain_active "$pid"; then
				log "Firewall is already active in the current namespace"
			else
				log "Firewall is missing in the current namespace; restoring"

				if ! "$INSTALL_PATH" apply; then
					warn "Failed to restore firewall; retrying in ${WATCH_INTERVAL_SECONDS}s"
				fi
			fi

			last_pid="$pid"
		else
			#
			# Даже при неизменном PID периодически проверяем,
			# что таблица случайно не была удалена.
			#
			if ! table_active "$pid" || ! chain_active "$pid"; then
				warn "Firewall table is missing; restoring"

				if ! "$INSTALL_PATH" apply; then
					warn "Failed to restore firewall; retrying in ${WATCH_INTERVAL_SECONDS}s"
				fi
			fi
		fi

		sleep "$WATCH_INTERVAL_SECONDS"
	done
}


remove_legacy_housekeeping() {
	systemctl \
		disable \
		--now \
		"$LEGACY_HOUSEKEEPING_TIMER" \
		"$LEGACY_HOUSEKEEPING_UNIT" \
		>/dev/null 2>&1 ||
		true

	rm -f \
		"/etc/systemd/system/${LEGACY_HOUSEKEEPING_TIMER}" \
		"/etc/systemd/system/${LEGACY_HOUSEKEEPING_UNIT}"

	rm -f \
		"/etc/systemd/system/timers.target.wants/${LEGACY_HOUSEKEEPING_TIMER}" \
		"/etc/systemd/system/multi-user.target.wants/${LEGACY_HOUSEKEEPING_UNIT}"
}


stop_existing_services() {
	systemctl \
		stop \
		"$WATCH_UNIT" \
		"$TIMER_UNIT" \
		"$REFRESH_UNIT" \
		"$LEGACY_HOUSEKEEPING_TIMER" \
		"$LEGACY_HOUSEKEEPING_UNIT" \
		>/dev/null 2>&1 ||
		true
}


write_systemd_units() {
	cat > "/etc/systemd/system/${WATCH_UNIT}" <<EOF
[Unit]
Description=Maintain Russian IP blocking for AmneziaWG clients
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} watch
Restart=always
RestartSec=5
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

	cat > "/etc/systemd/system/${REFRESH_UNIT}" <<EOF
[Unit]
Description=Refresh Russian IP networks for AmneziaWG
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply --refresh
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

	cat > "/etc/systemd/system/${TIMER_UNIT}" <<EOF
[Unit]
Description=Refresh Russian IP networks for AmneziaWG every 12 hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=12h
RandomizedDelaySec=5min
Persistent=true
Unit=${REFRESH_UNIT}

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload
}


print_firewall_status() {
	local pid="$1"

	nsenter \
		-t "$pid" \
		-n \
		nft list chain inet "$TABLE_NAME" forward
}


status_mode() {
	local container
	local pid
	local watch_status
	local timer_status

	require_root
	prepare_directories
	acquire_lock
	check_docker

	container="$(find_awg_container)" ||
		die "AmneziaWG container with ${AWG_IFACE} not found"

	pid="$(container_pid "$container")" ||
		die "Could not obtain container PID"

	printf '\n'
	printf 'Container: %s\n' "$container"
	printf 'Interface: %s\n' "$AWG_IFACE"
	printf 'PID:       %s\n' "$pid"
	printf '\n'

	if ! table_active "$pid"; then
		die "Blocking table ${TABLE_NAME} is NOT active"
	fi

	if ! chain_active "$pid"; then
		die "Blocking chain ${TABLE_NAME}/forward is NOT active"
	fi

	printf 'Firewall:\n\n'

	print_firewall_status "$pid"

	printf '\n'

	watch_status="$(
		systemctl is-active "$WATCH_UNIT" 2>/dev/null ||
			true
	)"

	timer_status="$(
		systemctl is-active "$TIMER_UNIT" 2>/dev/null ||
			true
	)"

	printf 'Services:\n'
	printf '  %-34s %s\n' "$WATCH_UNIT" "${watch_status:-unknown}"
	printf '  %-34s %s\n' "$TIMER_UNIT" "${timer_status:-unknown}"

	printf '\n'

	printf 'Cached lists:\n'

	if [[ -f "$RU4_FILE" ]]; then
		printf \
			'  IPv4: %s entries, %s\n' \
			"$(wc -l < "$RU4_FILE")" \
			"$(du -h "$RU4_FILE" | awk '{ print $1 }')"
	else
		printf '  IPv4: missing\n'
	fi

	if [[ -f "$RU6_FILE" ]]; then
		printf \
			'  IPv6: %s entries, %s\n' \
			"$(wc -l < "$RU6_FILE")" \
			"$(du -h "$RU6_FILE" | awk '{ print $1 }')"
	else
		printf '  IPv6: missing\n'
	fi

	if [[ -f "$RULESET_FILE" ]]; then
		printf \
			'  Rules: %s\n' \
			"$(du -h "$RULESET_FILE" | awk '{ print $1 }')"
	fi

	printf \
		'  Total: %s\n' \
		"$(du -sh "$STATE_DIR" 2>/dev/null | awk '{ print $1 }')"

	printf '\n'

	printf 'Next list refresh:\n'

	systemctl \
		list-timers \
		"$TIMER_UNIT" \
		--no-pager \
		--all \
		2>/dev/null ||
		true
}


install_mode() {
	local source_path

	require_root
	check_os
	install_dependencies
	check_docker
	prepare_directories
	check_free_space

	source_path="$(
		readlink -f "$0" 2>/dev/null ||
			true
	)"

	if [[ -z "$source_path" || ! -f "$source_path" ]]; then
		die "Save the script to a file first and run it with sudo bash ./awg-block-ru.sh"
	fi

	log "Stopping previous awg-block-ru services"

	stop_existing_services

	log "Removing legacy housekeeping service"

	remove_legacy_housekeeping

	if [[ "$source_path" != "$INSTALL_PATH" ]]; then
		log "Installing script to ${INSTALL_PATH}"

		install \
			-m 0755 \
			"$source_path" \
			"$INSTALL_PATH"
	else
		chmod 0755 "$INSTALL_PATH"
	fi

	log "Installing systemd units"

	write_systemd_units

	#
	# Сначала устанавливаем firewall без работающих фоновых
	# сервисов. Это полностью исключает гонку при установке.
	#
	log "Downloading lists and applying firewall rules"

	"$INSTALL_PATH" apply --refresh

	log "Initial firewall installation verified"

	#
	# Только после успешного apply запускаем watcher/timer.
	#
	log "Enabling automatic restore"

	systemctl enable "$WATCH_UNIT" >/dev/null
	systemctl start "$WATCH_UNIT"

	log "Enabling automatic list refresh"

	systemctl enable "$TIMER_UNIT" >/dev/null
	systemctl start "$TIMER_UNIT"

	#
	# status берёт тот же lock, что и apply.
	# Даже если timer внезапно запустится одновременно,
	# status дождётся завершения операции.
	#
	log "Installation completed successfully"

	"$INSTALL_PATH" status
}


remove_mode() {
	local container=""
	local pid=""

	require_root

	log "Stopping services"

	systemctl \
		disable \
		--now \
		"$WATCH_UNIT" \
		"$TIMER_UNIT" \
		"$REFRESH_UNIT" \
		"$LEGACY_HOUSEKEEPING_TIMER" \
		"$LEGACY_HOUSEKEEPING_UNIT" \
		>/dev/null 2>&1 ||
		true

	acquire_lock

	if command_exists docker && docker info >/dev/null 2>&1; then
		container="$(
			find_awg_container 2>/dev/null ||
				true
		)"

		if [[ -n "$container" ]]; then
			pid="$(
				container_pid "$container" 2>/dev/null ||
					true
			)"

			if [[ -n "$pid" ]] && table_active "$pid"; then
				log "Removing nftables table ${TABLE_NAME}"

				nsenter \
					-t "$pid" \
					-n \
					nft delete table inet "$TABLE_NAME" ||
					true
			fi
		fi
	fi

	rm -f \
		"/etc/systemd/system/${WATCH_UNIT}" \
		"/etc/systemd/system/${REFRESH_UNIT}" \
		"/etc/systemd/system/${TIMER_UNIT}" \
		"/etc/systemd/system/${LEGACY_HOUSEKEEPING_UNIT}" \
		"/etc/systemd/system/${LEGACY_HOUSEKEEPING_TIMER}"

	systemctl daemon-reload
	systemctl reset-failed >/dev/null 2>&1 || true

	rm -rf "$STATE_DIR"
	rm -rf "$RUNTIME_DIR"

	log "Removed ${APP_NAME}"
}


usage() {
	cat <<EOF
Usage:

Install / reinstall:
	sudo bash $0

Apply cached lists:
	sudo ${INSTALL_PATH} apply

Refresh lists and apply:
	sudo ${INSTALL_PATH} apply --refresh

Show firewall status:
	sudo ${INSTALL_PATH} status

Watch logs:
	sudo journalctl -u ${WATCH_UNIT} -f

Refresh logs:
	sudo journalctl -u ${REFRESH_UNIT} -n 100 --no-pager

Remove:
	sudo ${INSTALL_PATH} remove
EOF
}


main() {
	local command="${1:-install}"

	case "$command" in
		install)
			install_mode
			;;

		apply)
			if [[ "${2:-}" == "--refresh" ]]; then
				apply_rules true
			else
				apply_rules false
			fi
			;;

		watch)
			watch_mode
			;;

		status)
			status_mode
			;;

		remove)
			remove_mode
			;;

		help|-h|--help)
			usage
			;;

		*)
			usage
			die "Unknown command: ${command}"
			;;
	esac
}


main "$@"
