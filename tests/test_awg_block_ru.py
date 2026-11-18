import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "awg-block-ru.sh"
FUNCTIONS = SCRIPT.read_text().rsplit('\nmain "$@"', 1)[0]
GNU_MV = shutil.which("gmv") or (shutil.which("mv") if os.uname().sysname == "Linux" else None)


class FirewallTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.state = self.root / "state"
        self.state.mkdir()
        self.current = self.state / "current"
        self.active = self.root / "active"
        self.ipv4 = "".join(f"198.18.{i // 256}.{i % 256}/32\n" for i in range(500))
        self.ipv6 = "".join(f"2001:db8::{i:x}/128\n" for i in range(100))
        (self.root / "ipv4").write_bytes(self.ipv4.replace("\n", "\r\n").encode())
        (self.root / "ipv6").write_text("\n" + self.ipv6)

    def run_bash(self, code, **settings):
        return subprocess.run(
            ["bash", "-c", FUNCTIONS + "\n" + code, "test", str(self.root)],
            env={**os.environ, "GNU_MV": GNU_MV or "", **settings},
            capture_output=True,
            text=True,
            timeout=15,
        )

    def apply(self, refresh=True, **settings):
        if not GNU_MV:
            self.skipTest("GNU mv is needed to exercise the real cache publication")
        return self.run_bash(
            r'''
ROOT="$1"
STATE_DIR="${ROOT}/state"
RUNTIME_DIR="${ROOT}/runtime"
RU4_FILE="${STATE_DIR}/ru4.zone"
RU6_FILE="${STATE_DIR}/ru6.zone"
CACHE_LINK="${STATE_DIR}/current"
require_root() { :; }
check_free_space() { :; }
acquire_lock() { :; }
check_docker() { :; }
find_awg_container() { echo amnezia-awg2; }
container_pid() { echo 123; }
mv() { "$GNU_MV" "$@"; }
curl() {
    [[ "${FAIL_DOWNLOAD:-}" != yes ]] || return 1
    case "${@: -3:1}" in
        "$RU4_URL") cp "${ROOT}/ipv4" "${@: -1}" ;;
        "$RU6_URL") cp "${ROOT}/ipv6" "${@: -1}" ;;
        *) return 99 ;;
    esac
}
nsenter() {
    shift 3
    [[ "$1" == nft ]] || return 99
    shift
    case "$1" in
        --check) cp "$3" "${ROOT}/checked" ;;
        --file)
            cmp "$2" "${ROOT}/checked" || return 98
            [[ "${FAIL_NFT:-}" != yes ]] || return 1
            cp "$2" "${ROOT}/active"
            ;;
        list) test -s "${ROOT}/active" ;;
        *) return 97 ;;
    esac
}
apply_rules "$REFRESH"
''',
            REFRESH="true" if refresh else "false",
            **settings,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_refresh_applies_one_batch_and_publishes_both_lists(self):
        self.assert_success(self.apply())
        original = self.current.resolve()
        self.assertEqual((self.current / "ru4.zone").read_text(), self.ipv4)
        self.assertEqual((self.current / "ru6.zone").read_text(), self.ipv6)
        self.assertEqual(
            self.active.read_text().splitlines()[:3],
            [
                "add table inet awg_ru_block",
                "delete table inet awg_ru_block",
                "table inet awg_ru_block {",
            ],
        )
        self.assert_success(self.apply())
        self.assertNotEqual(self.current.resolve(), original)
        self.assertFalse(original.exists())

    def test_failed_load_keeps_active_rules_and_previous_cache(self):
        self.assert_success(self.apply())
        original = self.current.resolve()
        active = self.active.read_bytes()
        (self.root / "ipv4").write_text(self.ipv4.replace("198.18.", "198.19."))
        self.assertNotEqual(self.apply(FAIL_NFT="yes").returncode, 0)
        self.assertEqual(self.current.resolve(), original)
        self.assertEqual(list(self.state.glob("cache.*")), [original])
        self.assertEqual(self.active.read_bytes(), active)
        self.assertEqual(list((self.root / "runtime").iterdir()), [])

    def test_bad_cidr_never_reaches_nft(self):
        for filename, invalid in (("ipv4", "999.0.0.0/24"), ("ipv6", "::::/64")):
            with self.subTest(filename=filename):
                path = self.root / filename
                valid = path.read_bytes()
                path.write_bytes(valid + invalid.encode() + b"\n")
                result = self.apply()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CIDR", result.stderr)
                self.assertFalse((self.root / "checked").exists())
                self.assertFalse(self.current.is_symlink())
                self.assertEqual(list(self.state.glob("cache.*")), [])
                path.write_bytes(valid)

    def test_legacy_cache_restores_without_downloading(self):
        (self.state / "ru4.zone").write_text(self.ipv4)
        (self.state / "ru6.zone").write_text(self.ipv6)
        self.assert_success(self.apply(refresh=False, FAIL_DOWNLOAD="yes"))
        self.assertTrue(self.active.exists())
        self.assertFalse(self.current.is_symlink())

    def test_watcher_recovers_after_docker_becomes_available(self):
        result = self.run_bash(r'''
RUNTIME_DIR="$1"
cycle=0
INSTALL_PATH=mock_install
require_root() { :; }
prepare_directories() { :; }
check_docker() { die "Docker daemon is unavailable"; }
command_exists() { [[ "$1" == docker ]]; }
find_awg_container() {
    [[ "$cycle" -gt 0 ]] && echo amnezia-awg2
}
container_pid() { echo 123; }
table_active() { [[ -f "${RUNTIME_DIR}/restored" ]]; }
chain_active() { table_active; }
mock_install() {
    [[ "$1" == apply && ! -e "${RUNTIME_DIR}/restored" ]] || return 1
    touch "${RUNTIME_DIR}/restored"
}
sleep() {
    cycle=$((cycle + 1))
    if [[ "$cycle" -eq 3 ]]; then exit 0; fi
}
watch_mode
''')
        self.assert_success(result)
        self.assertTrue((self.root / "restored").exists())
        self.assertNotIn("Failed to restore", result.stderr)


if __name__ == "__main__":
    unittest.main()
