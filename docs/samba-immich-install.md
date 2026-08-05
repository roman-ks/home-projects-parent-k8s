# Samba + Immich + Kopia — install

Three charts converted from the reference compose projects:

- **`charts/samba`** — SMB server (`servercontainers/samba`), namespace `samba`, two shares
  (`user`, `imuser`), exposed on the LAN via a LoadBalancer on `:445`.
- **`charts/immich-wrapper`** — the community `immich` chart (server + valkey) + immich's
  `pgvecto`/`vectorchord` postgres, OIDC via authentik, traefik ingress at `immich.pi.home`.
- **`charts/kopia`** — per-target S3 backup (one release per bucket). The `immich` target backs up the
  external library; UI is scaled to zero, snapshots run from a CronJob.

**Shared storage.** The `imuser` SMB share, Immich's external library, and Kopia's backup source are
the **same directory** (`/mnt/drive1/pv/immich-external`). A directory can only bind to one PVC, so
each namespace gets its own `local` PV pointing at that path: **samba = writer**, **immich = reader**,
**kopia = reader**. All PVs are `local` + `nodeAffinity` + `Retain` + `helm.sh/resource-policy: keep`,
so data survives `helm uninstall`.

---

## Prerequisites

These platform pieces must be up first (see `bootstrap-recipes.md` / `setup.md` for the node bootstrap):

1. **k3s node + encrypted drive**: `just bootstrap unlock` (mounts `/mnt/drive1`) and
   `just bootstrap pv-dir` (creates the static PV dirs, incl. `immich-external`).
2. **Traefik + authentik SSO middleware**: `just bootstrap traefik` (syncs
   `k3s/server/manifests/`, incl. the `authentik-forward-auth` Middleware and cross-namespace refs).
3. **cert-manager + internal CA issuer**: `just cert-manager`, `just pki`, then
   `just bootstrap intermediate-ca` (generates the intermediate from your offline root and loads it —
   the `internal-ca` ClusterIssuer goes Ready). Ingress TLS is auto-issued after this.
4. **authentik** running at `auth.pi.home` with `just authentik` + `just authentik-secret`, and the
   blueprints applied (the `oidc-immich` provider for Immich, and the Traefik proxy-auth provider for
   the Kopia UI). `authentik-secret` also injects the `OAUTH_IMMICH_*` creds onto the authentik pods.
5. **Kopia only** — an **S3 bucket + IAM user/policy** created in AWS (one-time, out of cluster).

All of the above assume their own secrets are already in sops (see **Secrets**).

---

## Install (secrets already in sops)

Assumes every `values/*.enc.yaml` is filled and encrypted. Each `*-secret` recipe decrypts in a
RAM-backed tmpdir and prompts the **YubiKey**.

### Samba
```bash
just samba-secret          # applies the samba-accounts secret (YubiKey)
just samba
kubectl -n samba get svc samba     # EXTERNAL-IP = <node-ip>
#  smb://<node-ip>/User%20Share    (user)
#  smb://<node-ip>/Imuser%20Share  (imuser, = immich external library)
```

### Immich
```bash
just immich                # YubiKey (decrypts config + DB password each deploy)
```
Browse `https://immich.pi.home` → **Login with OAuth** → authentik. Immich trusts the internal CA via
the `ca.crt` in its own cert-manager cert (`NODE_EXTRA_CA_CERTS`), so the OIDC backchannel works.

### Kopia (immich backup target)
```bash
just kopia-secret immich   # applies kopia-immich-secrets (bucket + S3 creds + repo password; YubiKey)
just kopia immich          # release kopia-immich: CronJob + (scaled-to-0) UI

# run a backup now instead of waiting for the schedule:
kubectl -n kopia create job --from=cronjob/kopia-immich-backup kopia-test
kubectl -n kopia logs job/kopia-test -f     # "Connected to existing…"/"creating a new one" + JSON stats

# browse/restore on demand (UI polls S3 while up, so scale back down after):
just kopia-ui immich       # scale UI to 1  ->  https://kopia-immich.pi.home (authentik SSO)
just kopia-ui immich 0     # scale UI to 0
```
Backup **status without the UI**: `kubectl -n kopia get jobs` (success/failure) and the Job logs
(`kopia snapshot create --json` prints file count/size/errors/duration).

**Adding another backup target** (e.g. a samba folder → its own bucket): create
`values/kopia-<name>.yaml` (source path/hostPath, `server.host`, `repo.secretName: kopia-<name>-secrets`)
and `values/kopia-<name>.enc.yaml` (the secret), then `just kopia-secret <name>` + `just kopia <name>`.

---

## Secrets — what's in each file and how to update

**How to edit any sops file:** `sops values/<file>` opens it decrypted in `$EDITOR` and re-encrypts on
save (YubiKey to open). Then re-run the matching apply recipe. Never hand-edit `ENC[...]` blobs.

| File | Holds | Re-apply with | Notes |
|---|---|---|---|
| `values/samba.enc.yaml` | Secret `samba-accounts`: `user-password`, `imuser-password` | `just samba-secret` | Changing a password → SMB clients reconnect. Fully encrypted manifest. |
| `values/immich.enc.yaml` | `immich.oidc.{clientId,clientSecret}` (authentik **provider** side) | `just authentik-secret` | Must stay in sync with `immich-config.enc.yaml`. Fully encrypted. |
| `values/immich-config.enc.yaml` | `postgres.password` + oauth `clientId`/`clientSecret` (+ plaintext immich config) | `just immich` | **Partially** encrypted (`encrypted_regex: ^(password\|clientId\|clientSecret)$`) — the rest of the config stays diffable. oauth creds must match `immich.enc.yaml`. |
| `values/kopia-immich.enc.yaml` | Secret `kopia-immich-secrets`: `KOPIA_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `KOPIA_PASSWORD` | `just kopia-secret immich` | The Secret's `metadata.name` **must equal** `repo.secretName` in `values/kopia-immich.yaml`. Fully encrypted. |

**When you'd update each:**

- **Rotate an SMB password** → edit `samba.enc.yaml`, `just samba-secret` (no redeploy of samba needed).
- **Rotate the Immich OIDC client secret** (regenerated in authentik) → update **both**
  `immich.enc.yaml` *and* `immich-config.enc.yaml`, then `just authentik-secret` **and** `just immich`.
- **Change the Immich DB password** → edit `immich-config.enc.yaml`, `just immich`. (New installs only —
  changing it against an existing postgres volume won't re-key the DB.)
- **Rotate Kopia S3 credentials** → edit `kopia-immich.enc.yaml`, `just kopia-secret immich`.
- **KOPIA_PASSWORD** → ⚠️ **do not change on an existing repo.** The repo's encryption is derived from
  it; a new password can't open the old repo, and it can't be changed in place. It's a permanent secret —
  back it up.

> Prerequisite secrets (not part of these apps): `values/authentik.enc.yaml` (authentik core +
> db creds) is applied by `just authentik-secret` alongside the two oidc files above.

---

## Shared-folder permissions (handled automatically)

No manual step. The samba chart:

- runs an initContainer that **`chown -R`**s each share to its SMB user's UID on startup — this fixes
  both the fresh `root:root` mount *and* any files you copy into the share out-of-band (e.g. bulk-copied
  photos owned by another UID), and
- forces the `imuser` share to create **other-readable** files/dirs (`create/directory mode 0644/0755`).

So samba (`imuser`, UID `3002`) can write everywhere in the share, and Immich/Kopia (different UIDs,
read-only) can index it — no shared group or `fsGroup` needed.

> The recursive chown traverses the whole share on each samba pod start; for a very large library that
> adds some startup time (metadata only, no data reads). Files samba creates afterwards are already
> correctly owned, so it's a no-op once consistent.

---

## Notes & caveats

- **Per-deploy YubiKey tap for immich.** The community chart couples the config (which holds the OIDC
  secret) into the main release, so `just immich` decrypts on every deploy.
- **First-deploy cert timing.** Immich and the Kopia UI mount their own cert-manager cert for the CA
  bundle; on first deploy the pod waits in `ContainerCreating` until cert-manager issues it (seconds).
- **Kopia UI is `replicas: 0`.** A running server periodically polls S3 (billed) — hence scale-on-demand.
  Backups and repository maintenance run from the CronJob regardless (same `nobody@pi-kopia` identity).
- **External-library ingestion** relies on Immich's scheduled `library.scan` cron (the built-in file
  watcher is experimental/unreliable; the inotify sidecar from the compose wasn't migrated).
- **Uninstall keeps data.** All PVs/PVCs are `keep` + `Retain`; `helm uninstall` leaves the hostPath data
  (including the shared external library). Kopia's connect-or-create is idempotent, so redeploys reconnect.
