# awg-block-ru

Blocks traffic from AmneziaWG clients to Russian IPv4 and IPv6 networks. The
installer expects Linux with systemd and a local Docker daemon.

```sh
sudo bash ./awg-block-ru.sh install
sudo /usr/local/sbin/awg-block-ru status
```

## Roll back to an uninstalled state

```sh
sudo bash ./rollback.sh --dry-run
sudo bash ./rollback.sh
```

This removes the blocking table from running Amnezia containers, the installed
script, its cache and runtime files, its systemd units and timers, and the
legacy journald drop-in. The VPN keeps running, but the block is lifted. Do
not run the installer or a manual refresh concurrently with the rollback.

If you know `/etc/docker/daemon.json` **did not exist before the original
version was installed**, pass `--docker-config-was-absent` to both commands.
Rollback will remove the file only if it contains exactly the legacy logging
settings. Otherwise, restore the original Docker configuration from your
own backup. Rollback does not restart Docker or Amnezia, revert settings on
already-created containers, uninstall packages, or recover data deleted by
past disk cleanup.
