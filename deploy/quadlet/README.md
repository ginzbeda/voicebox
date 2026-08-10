# Quadlet units (rootless Podman + systemd)

Source of truth for running Voicebox as a systemd-managed service under rootless Podman.

Install:

```bash
cp deploy/quadlet/voicebox.* ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start voicebox.service
loginctl enable-linger "$USER"   # start without an active login session
```

`WantedBy=default.target` in each `[Install]` section is what wires them to boot — quadlet
units are generated, so `systemctl enable` does not apply to them.

## Why these live in the repo

`~/.config/containers/systemd/` is not version controlled, and on this setup it has been
regenerated from another source at least once — silently deleting these files and leaving the
service unstartable (`Unit voicebox.service not found`) with the containers gone. Keeping the
originals here makes that a copy away from recovery. Re-copy after any regeneration.

## Notes that are easy to get wrong

- **`restart` does not work.** The pod's `exit-policy stop` tears the pod down when the
  container exits, so `systemctl --user restart voicebox.service` races its own dependency and
  fails. Use `stop` then `start`.
- **The image tag matters.** The unit runs `localhost/voicebox:latest`, which is a *tag* on the
  compose-built image. After `podman-compose build`, retag it or you silently redeploy the old
  image:
  `podman tag localhost/podman-hosting_voicebox:latest localhost/voicebox:latest`
- **Volume names keep the `podman-hosting_` prefix deliberately.** They hold the profile
  database, captures, generated audio, and ~24 GB of models. Renaming them orphans all of it.
- **`redi-internal` is referenced by plain name**, not as a `.network` unit, because that unit
  does not exist here — only the podman network does. Referencing a missing unit makes the pod
  fail to start.
