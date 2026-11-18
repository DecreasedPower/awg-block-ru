import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "rollback.sh"
LEGACY_LOGGING = {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}


class RollbackTests(unittest.TestCase):
    def setUp(self):
        sandbox = tempfile.TemporaryDirectory()
        self.addCleanup(sandbox.cleanup)
        self.root = Path(sandbox.name)
        self.config = self.root / "daemon.json"
        self.config.write_text(json.dumps(LEGACY_LOGGING))
        self.table = self.root / "table"
        self.table.touch()
        self.install = self.root / "installed-script"
        self.install.touch()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.journal = self.root / "journald.conf"
        self.journal.touch()
        self.units = self.root / "units"
        self.units.mkdir()
        (self.units / "awg-block-ru-watch.service").touch()
        wants = self.units / "multi-user.target.wants"
        wants.mkdir()
        (wants / "awg-block-ru-watch.service").symlink_to("../awg-block-ru-watch.service")
        (self.units / "docker.service").touch()
        self.actions = self.root / "actions"

    def run_rollback(self, *args):
        return subprocess.run(
            ["bash", "-c", r'''
source "$1"
root="$2"
shift 2
INSTALL_PATH="$root/installed-script"
STATE_DIR="$root/cache"
RUNTIME_DIR="$root/runtime"
LOCK_FILE="$root/lock"
UNIT_DIR="$root/units"
JOURNALD_DROPIN="$root/journald.conf"
DOCKER_CONFIG="$root/daemon.json"
require_root() { :; }
docker() { :; }
flock() { :; }
nft() { :; }
nsenter() { :; }
docker_local() {
    [[ ! -e "$root/docker-down" ]] || return 1
    printf '%s\n' amnezia-awg2 unrelated
}
visit_table() {
    [[ "$2" == amnezia-awg2 ]] || return 1
    [[ -e "$root/table" ]] || return 0
    if [[ "$1" == remove ]]; then
        rm "$root/table"
    else
        printf '%s\n' 'Remove table inet awg_ru_block in amnezia-awg2'
    fi
}
systemctl() {
    if [[ "$1" == show ]]; then
        printf '%s\n' inactive
    else
        printf '%s\n' "$*" >> "$root/actions"
    fi
}
main "$@"
''', "test", str(SCRIPT), str(self.root), *args],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_dry_run_changes_nothing(self):
        result = self.run_rollback("--dry-run", "--docker-config-was-absent")
        self.assert_success(result)
        self.assertIn("Remove table inet awg_ru_block", result.stdout)
        self.assertIn(str(self.config), result.stdout)
        for path in (self.table, self.install, self.cache, self.journal, self.config):
            self.assertTrue(path.exists())
        self.assertFalse(self.actions.exists())
        self.assertFalse((self.root / "lock").exists())

    def test_cleanup_is_scoped_and_idempotent(self):
        self.assert_success(self.run_rollback())
        for path in (self.table, self.install, self.cache, self.journal, self.root / "lock"):
            self.assertFalse(path.exists())
        self.assertTrue(self.config.exists())
        self.assertTrue((self.units / "docker.service").exists())
        self.assertEqual(list(self.units.glob("awg-block-ru-*")), [])
        self.assertEqual(list((self.units / "multi-user.target.wants").iterdir()), [])
        actions = self.actions.read_text().splitlines()
        self.assertEqual(actions, [
            "stop awg-block-ru-watch.service",
            "daemon-reload",
            "restart systemd-journald",
        ])
        result = self.run_rollback()
        self.assert_success(result)
        self.assertIn("already absent", result.stdout)
        self.assertEqual(self.actions.read_text().splitlines(), actions)

    def test_exact_legacy_docker_config_can_be_removed(self):
        self.assert_success(self.run_rollback("--docker-config-was-absent"))
        self.assertFalse(self.config.exists())

    def test_refuses_to_remove_custom_docker_config_before_any_changes(self):
        self.config.write_text(json.dumps({**LEGACY_LOGGING, "ipv6": True}))
        result = self.run_rollback("--docker-config-was-absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the exact legacy settings", result.stderr)
        self.assertTrue(self.config.exists())
        self.assertTrue(self.table.exists())
        self.assertFalse(self.actions.exists())

    def test_unavailable_docker_aborts_before_stopping_services(self):
        (self.root / "docker-down").touch()
        result = self.run_rollback()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Aborted before changing rules or services", result.stderr)
        self.assertTrue(self.table.exists())
        self.assertFalse(self.actions.exists())


if __name__ == "__main__":
    unittest.main()
