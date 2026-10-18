#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="awg-block-ru"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
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
HOUSEKEEPING_UNIT="${APP_NAME}-housekeeping.service"
HOUSEKEEPING_TIMER_UNIT="${APP_NAME}-housekeeping.timer"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/${APP_NAME}-limits.conf"
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
	printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
	printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

on_error() {
	local rc="$1"
	local line="$2"
	local cmd="$3"

	printf '[%s] ERROR: command failed (exit=%s, line=%s): %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$rc" \
		"$line" \
		"$cmd" >&2

	exit "$rc"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
	[[ ${EUID} -eq 0 ]] || die "Run this script as root: sudo bash $0"
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
	local packages=()

	command_exists curl || packages+=(curl)
	command_exists ip || packages+=(iproute2)
	command_exists nft || packages+=(nftables)
	command_exists nsenter || packages+=(util-linux)
	command_exists flock || packages+=(util-linux)
	command_exists python3 || packages+=(python3)

	if [[ ${#packages[@]} -gt 0 ]]; then
		command_exists apt-get || die "apt-get not found. Ubuntu/Debian was expected."

		log "Installing dependencies: ${packages[*]}"

		export DEBIAN_FRONTEND=noninteractive

		apt-get update

		apt-get install -y \
			--no-install-recommends \
			ca-certificates \
			"${packages[@]}"
	fi
}

check_docker() {
	command_exists docker ||
		die "docker command not found. AmneziaWG server is expected to run in Docker."

	docker info >/dev/null 2>&1 ||
		die "Docker daemon is unavailable. Check: systemctl status docker"
}

container_pid() {
	local name="$1"
	local pid

	pid="$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || true)"

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	[[ "$pid" -gt 0 ]] || return 1

	printf '%s\n' "$pid"
}

find_awg_container() {
	local pid
	local name

	if pid="$(container_pid "$PRIMARY_CONTAINER")"; then
		if nsenter -t "$pid" -n ip link show "$AWG_IFACE" >/dev/null 2>&1; then
			printf '%s\n' "$PRIMARY_CONTAINER"
			return 0
		fi
	fi

	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		[[ "$name" == amnezia* ]] || continue

		if pid="$(container_pid "$name")"; then
			if nsenter -t "$pid" -n ip link show "$AWG_IFACE" >/dev/null 2>&1; then
				printf '%s\n' "$name"
				return 0
			fi
		fi
	done < <(docker ps --format '{{.Names}}')

	return 1
}

validate_ipv4_file() {
	local file="$1"
	local count

	count="$(grep -cve '^[[:space:]]*$' "$file" || true)"

	[[ "$count" -ge 500 ]] ||
		die "IPv4 list looks too small: ${count} entries"

	if grep -Evm1 \
		'^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$' \
		"$file" >/dev/null; then

		die "IPv4 list contains unexpected data; refusing to load it"
	fi
}

validate_ipv6_file() {
	local file="$1"
	local count

	count="$(grep -cve '^[[:space:]]*$' "$file" || true)"

	[[ "$count" -ge 100 ]] ||
		die "IPv6 list looks too small: ${count} entries"

	if grep -Evm1 \
		'^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' \
		"$file" >/dev/null; then

		die "IPv6 list contains unexpected data; refusing to load it"
	fi
}

download_lists() {
	local tmp4
	local tmp6

	mkdir -p "$STATE_DIR"

	find "$STATE_DIR" \
		-maxdepth 1 \
		-type f \
		\( \
			-name 'ru4.??????' \
			-o -name 'ru6.??????' \
			-o -name 'ru4.??????.clean' \
			-o -name 'ru6.??????.clean' \
		\) \
		-mmin +60 \
		-delete \
		2>/dev/null || true

	tmp4="$(mktemp "${STATE_DIR}/ru4.XXXXXX")"
	tmp6="$(mktemp "${STATE_DIR}/ru6.XXXXXX")"

	log "Downloading RU IPv4 list from IPdeny"

	curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--connect-timeout 15 \
		--max-time 60 \
		"$RU4_URL" \
		-o "$tmp4"

	log "Downloading RU IPv6 list from IPdeny"

	curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--connect-timeout 15 \
		--max-time 60 \
		"$RU6_URL" \
		-o "$tmp6"

	sed -i 's/\r$//' "$tmp4" "$tmp6"

	grep -v '^[[:space:]]*$' "$tmp4" > "${tmp4}.clean"
	grep -v '^[[:space:]]*$' "$tmp6" > "${tmp6}.clean"

	mv "${tmp4}.clean" "$tmp4"
	mv "${tmp6}.clean" "$tmp6"

	validate_ipv4_file "$tmp4"
	validate_ipv6_file "$tmp6"

	install -m 0644 "$tmp4" "$RU4_FILE"
	install -m 0644 "$tmp6" "$RU6_FILE"

	rm -f "$tmp4" "$tmp6"

	log "Lists updated: IPv4=$(wc -l < "$RU4_FILE"), IPv6=$(wc -l < "$RU6_FILE")"
}

lists_exist() {
	[[ -s "$RU4_FILE" && -s "$RU6_FILE" ]]
}

build_ruleset() {
	validate_ipv4_file "$RU4_FILE"
	validate_ipv6_file "$RU6_FILE"

	{
		echo "table inet ${TABLE_NAME} {"

		echo '	set ru4 {'
		echo '		type ipv4_addr'
		echo '		flags interval'
		printf '		elements = { '

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

		echo '	}'

		echo '	set ru6 {'
		echo '		type ipv6_addr'
		echo '		flags interval'
		printf '		elements = { '

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

		echo '	}'

		echo '	chain forward {'
		echo '		type filter hook forward priority -100; policy accept;'
		printf '		iifname "%s" ip daddr @ru4 counter reject\n' "$AWG_IFACE"
		printf '		iifname "%s" ip6 daddr @ru6 counter reject\n' "$AWG_IFACE"
		echo '	}'

		echo '}'
	} > "$RULESET_FILE"
}

apply_rules() {
	local force_refresh="${1:-false}"
	local container
	local pid
	local check_ruleset

	exec 9>"$LOCK_FILE"

	flock -w 30 9 ||
		die "Could not acquire lock: $LOCK_FILE"

	check_docker

	if [[ "$force_refresh" == "true" ]] || ! lists_exist; then
		download_lists
	fi

	container="$(find_awg_container)" ||
		die "Running AmneziaWG container with interface ${AWG_IFACE} was not found. Expected ${PRIMARY_CONTAINER}."

	pid="$(container_pid "$container")" ||
		die "Could not obtain PID for container ${container}"

	log "Using container=${container}, pid=${pid}, interface=${AWG_IFACE}"

	build_ruleset

	#
	# Сначала проверяем новый ruleset.
	# Текущие рабочие правила при ошибке не удаляются.
	#
	check_ruleset="${RULESET_FILE}.check"

	sed \
		"1s/table inet ${TABLE_NAME}/table inet ${TABLE_NAME}_check/" \
		"$RULESET_FILE" \
		> "$check_ruleset"

	nsenter \
		-t "$pid" \
		-n \
		nft \
		--check \
		--file "$check_ruleset"

	rm -f "$check_ruleset"

	#
	# Только после успешной проверки заменяем активную таблицу.
	#
	if nsenter \
		-t "$pid" \
		-n \
		nft list table inet "$TABLE_NAME" \
		>/dev/null 2>&1; then

		nsenter \
			-t "$pid" \
			-n \
			nft delete table inet "$TABLE_NAME"
	fi

	nsenter \
		-t "$pid" \
		-n \
		nft \
		--file "$RULESET_FILE"

	if ! nsenter \
		-t "$pid" \
		-n \
		nft list table inet "$TABLE_NAME" \
		>/dev/null 2>&1; then

		die "nftables table was not created"
	fi

	log "RU IPv4/IPv6 blocking is active for traffic entering via ${AWG_IFACE}"
}

watch_mode() {
	log "Starting Docker event watcher"

	if ! "$INSTALL_PATH" apply; then
		warn "Initial rule application failed. Watcher will keep running."
	fi

	while true; do
		while IFS= read -r name; do
			[[ -n "$name" ]] || continue

			if [[ "$name" == "$PRIMARY_CONTAINER" || "$name" == amnezia* ]]; then
				log "Container started: ${name}; reapplying rules"

				for attempt in {1..15}; do
					sleep 2

					if "$INSTALL_PATH" apply; then
						break
					fi

					if [[ "$attempt" -eq 15 ]]; then
						warn "Failed to reapply rules after container start: ${name}"
					else
						log "AmneziaWG is not ready yet; retrying (${attempt}/15)"
					fi
				done
			fi
		done < <(
			docker events \
				--filter type=container \
				--filter event=start \
				--format '{{.Actor.Attributes.name}}'
		)

		warn "docker events stream ended; reconnecting in 3 seconds"

		sleep 3
	done
}

write_systemd_units() {
	cat > "/etc/systemd/system/${WATCH_UNIT}" <<EOF
[Unit]
Description=Block Russian IP networks for AmneziaWG clients
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	cat > "/etc/systemd/system/${REFRESH_UNIT}" <<EOF
[Unit]
Description=Refresh Russian IP networks for AmneziaWG
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply --refresh
EOF

	cat > "/etc/systemd/system/${TIMER_UNIT}" <<EOF
[Unit]
Description=Refresh Russian IP networks for AmneziaWG every 12 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=12h
Persistent=true
Unit=${REFRESH_UNIT}

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload
}

configure_disk_protection() {
	local docker_config_changed

	install -d -m 0755 /etc/systemd/journald.conf.d

	cat > "$JOURNALD_DROPIN" <<EOF
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=25M
MaxRetentionSec=7day
EOF

	install -d -m 0755 /etc/docker

	docker_config_changed="$(python3 - "$DOCKER_DAEMON_CONFIG" <<'PY'
import json
import os
import sys

path = sys.argv[1]

if os.path.exists(path):
    with open(path, encoding="utf-8") as file:
        config = json.load(file)
else:
    config = {}

driver = config.get("log-driver")

if driver not in (None, "json-file"):
    print("false")
    raise SystemExit

config["log-driver"] = "json-file"
log_options = config.setdefault("log-opts", {})
log_options["max-size"] = "10m"
log_options["max-file"] = "3"

temporary_path = f"{path}.tmp"

with open(temporary_path, "w", encoding="utf-8") as file:
    json.dump(config, file, indent=2)
    file.write("\n")

os.chmod(temporary_path, 0o644)
os.replace(temporary_path, path)
print("true")
PY
)"

	if [[ "$docker_config_changed" != "true" ]]; then
		warn "Docker uses a non-json-file logging driver; its configuration was left unchanged."
	fi

	cat > "/etc/systemd/system/${HOUSEKEEPING_UNIT}" <<EOF
[Unit]
Description=Safe disk housekeeping for AmneziaWG server
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/apt-get clean
ExecStart=/usr/bin/journalctl --vacuum-size=50M
ExecStart=/usr/bin/docker image prune --force --filter until=168h
ExecStart=/usr/bin/docker builder prune --force --filter until=168h
EOF

	cat > "/etc/systemd/system/${HOUSEKEEPING_TIMER_UNIT}" <<EOF
[Unit]
Description=Weekly disk housekeeping for AmneziaWG server

[Timer]
OnBootSec=30min
OnUnitActiveSec=7d
RandomizedDelaySec=1h
Persistent=true
Unit=${HOUSEKEEPING_UNIT}

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload
	systemctl restart systemd-journald

	if [[ "$docker_config_changed" == "true" ]]; then
		systemctl reload docker ||
			warn "Docker could not reload its logging limits; they will apply after its next restart."
	fi

	systemctl enable --now "$HOUSEKEEPING_TIMER_UNIT"
	systemctl start "$HOUSEKEEPING_UNIT"
}

install_mode() {
	local source_path

	require_root
	install_dependencies
	check_docker

	source_path="$(readlink -f "$0" 2>/dev/null || true)"

	[[ -n "$source_path" && -f "$source_path" ]] ||
		die "Save the script to a file first, then run: sudo bash ./awg-block-ru.sh"

	mkdir -p "$STATE_DIR"

	if [[ "$source_path" != "$INSTALL_PATH" ]]; then
		install -m 0755 "$source_path" "$INSTALL_PATH"
	else
		chmod 0755 "$INSTALL_PATH"
	fi

	write_systemd_units
	configure_disk_protection

	log "Downloading lists and applying firewall rules"

	"$INSTALL_PATH" apply --refresh

	log "Enabling automatic restore and list refresh"

	systemctl enable "$WATCH_UNIT"
	systemctl restart "$WATCH_UNIT"

	systemctl enable "$TIMER_UNIT"
	systemctl restart "$TIMER_UNIT"

	log "Installation completed successfully"

	"$INSTALL_PATH" status
}

status_mode() {
	local container
	local pid

	require_root
	check_docker

	container="$(find_awg_container)" ||
		die "AmneziaWG container with ${AWG_IFACE} not found"

	pid="$(container_pid "$container")" ||
		die "Could not obtain container PID"

	printf '\nContainer: %s\n' "$container"
	printf 'Interface: %s\n' "$AWG_IFACE"
	printf 'PID: %s\n\n' "$pid"

	if nsenter \
		-t "$pid" \
		-n \
		nft list table inet "$TABLE_NAME" \
		>/dev/null 2>&1; then

		nsenter \
			-t "$pid" \
			-n \
			nft list chain inet "$TABLE_NAME" forward
	else
		die "Blocking table ${TABLE_NAME} is NOT active"
	fi

	printf '\nServices:\n'

	systemctl \
		--no-pager \
		--full \
		status "$WATCH_UNIT" \
		2>/dev/null |
		sed -n '1,8p' || true

	systemctl \
		--no-pager \
		--full \
		status "$TIMER_UNIT" \
		2>/dev/null |
		sed -n '1,8p' || true

	systemctl \
		--no-pager \
		--full \
		status "$HOUSEKEEPING_TIMER_UNIT" \
		2>/dev/null |
		sed -n '1,8p' || true

	printf '\nCached lists:\n'

	if [[ -f "$RU4_FILE" ]]; then
		printf \
			'IPv4: %s entries, modified %s\n' \
			"$(wc -l < "$RU4_FILE")" \
			"$(stat -c '%y' "$RU4_FILE")"
	fi

	if [[ -f "$RU6_FILE" ]]; then
		printf \
			'IPv6: %s entries, modified %s\n' \
			"$(wc -l < "$RU6_FILE")" \
			"$(stat -c '%y' "$RU6_FILE")"
	fi
}

remove_mode() {
	local container
	local pid

	require_root

	systemctl disable --now \
		"$WATCH_UNIT" \
		"$TIMER_UNIT" \
		"$HOUSEKEEPING_TIMER_UNIT" \
		2>/dev/null || true

	systemctl stop \
		"$REFRESH_UNIT" \
		"$HOUSEKEEPING_UNIT" \
		2>/dev/null || true

	rm -f \
		"/etc/systemd/system/${WATCH_UNIT}" \
		"/etc/systemd/system/${REFRESH_UNIT}" \
		"/etc/systemd/system/${TIMER_UNIT}" \
		"/etc/systemd/system/${HOUSEKEEPING_UNIT}" \
		"/etc/systemd/system/${HOUSEKEEPING_TIMER_UNIT}" \
		"$JOURNALD_DROPIN"

	systemctl daemon-reload
	systemctl restart systemd-journald

	if command_exists docker && docker info >/dev/null 2>&1; then
		if container="$(find_awg_container 2>/dev/null)"; then
			if pid="$(container_pid "$container")"; then
				nsenter \
					-t "$pid" \
					-n \
					nft delete table inet "$TABLE_NAME" \
					2>/dev/null || true
			fi
		fi
	fi

	rm -rf "$STATE_DIR"
	rm -f "$INSTALL_PATH"

	log "Removed ${APP_NAME} rules, services and cached lists"
}

usage() {
	cat <<EOF
Usage:

Install:
	sudo bash $0

Apply cached lists:
	sudo ${INSTALL_PATH} apply

Refresh RU lists and apply:
	sudo ${INSTALL_PATH} apply --refresh

Show status and counters:
	sudo ${INSTALL_PATH} status

Remove everything:
	sudo ${INSTALL_PATH} remove

Show watcher logs:
	sudo journalctl -u ${WATCH_UNIT} -n 100 --no-pager

Disk protection:
	journald is limited to 50 MB
	Docker json-file logs are limited to 3 x 10 MB
	APT and unused Docker build data are cleaned weekly
EOF
}

main() {
	local command="${1:-install}"

	case "$command" in
		install)
			install_mode
			;;

		apply)
			require_root
			install_dependencies

			if [[ "${2:-}" == "--refresh" ]]; then
				apply_rules true
			else
				apply_rules false
			fi
			;;

		watch)
			require_root
			watch_mode
			;;

		status)
			status_mode
			;;

		remove)
			remove_mode
			;;

		-h|--help|help)
			usage
			;;

		*)
			usage
			die "Unknown command: $command"
			;;
	esac
}

main "$@"
