# claude-code-ui compose stack

Traefik (TLS + reverse proxy) and oauth2-proxy (username/password login) in
front of [CloudCLI](https://cloudcli.ai), the npm package for
[siteboon/claudecodeui](https://github.com/siteboon/claudecodeui).

CloudCLI runs on the host, started by `run.sh` — not in a container. Docker
Compose only runs Traefik, oauth2-proxy, a `whoami` test route, and a one-shot
init container that creates CloudCLI's first user.

## Request flow

```mermaid
graph TD
    user["User"] -->|1. Request| traefik["Traefik"]
    traefik -->|2. ForwardAuth| oauth["oauth2-proxy"]
    oauth -->|3. No session: show sign_in.html| user
    oauth -->|3. Valid session| traefik
    traefik -->|4. Proxy request| backend["CloudCLI"]
```

Traefik forwards every request to oauth2-proxy for a ForwardAuth check. Without
a valid session, oauth2-proxy serves `sign_in.html` for htpasswd credentials;
once authenticated, Traefik proxies the request on to CloudCLI.

## Layout

- `docker-compose.yml` — Traefik, oauth2-proxy, whoami, cloudcli-init.
- `sign_in.html` — oauth2-proxy's sign-in page (username/password only).
- `.htpasswd` — basic-auth credentials for oauth2-proxy. Gitignored.
- `.env` — config and credentials, copied from `.env.example`. Gitignored.
- `data/` — CloudCLI's SQLite DB, pid file, and log. Gitignored.

## Env vars

Copy `.env.example` to `.env` and fill in:

| Var | Purpose |
|---|---|
| `LE_ACCOUNT_EMAIL` | Let's Encrypt account email |
| `SERVER_FQDN` | Public hostname of this host |
| `CLOUDCLI_DATA_DIR` | Host dir for CloudCLI's DB/pid/log |
| `CLOUDCLI_INIT_USERNAME` / `CLOUDCLI_INIT_PASSWORD` | CloudCLI's first user |
| `*_VERSION` | Pinned image/binary versions |

## Running

```
./run.sh                    # (re)start docker compose; leave a running CloudCLI alone
./run.sh --restart-cloudcli # also stop and restart the CloudCLI process
```

`run.sh` uses the `cloudcli` binary if it's on `PATH`, otherwise
`npx -y @cloudcli-ai/cloudcli`.

## Before exposing publicly

- Change `CLOUDCLI_INIT_PASSWORD` in `.env`.
- Replace `.htpasswd` with your own user(s): `htpasswd -c .htpasswd <user>`.

## TODO

- Fix the double login: users hit oauth2-proxy's sign-in page first, then
  CloudCLI's own login screen. CloudCLI has a build-time `IS_PLATFORM` flag
  meant to skip its login, but it's baked in at Vite build time in the
  published npm package, so setting it at runtime has no effect.
