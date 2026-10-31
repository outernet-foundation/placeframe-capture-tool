# placeframe-capture-tool

The capture tier of [Placeframe](https://github.com/outernet-foundation/placeframe), extracted as a standalone repo: the phone-side Unity CaptureTool app and the ZED-box appliance (zed-capture service, AOA bridge/gateway, box observability). One repo, not a phone/box pair — the AOA tether couples them, and `PlaceframeZedCaptureClient`'s only consumer stays co-located. placeframe remains the server stack; the two repos join via PyPI registry pins (`placeframe-common`/`placeframe-core`) on independent cadences — the zed-capture client never crosses the repo boundary (consumed via `file:`, never published).

## Commands

All from the repo root. The devkits (`docker-devkit`, `python-devkit`, `openapi-client-codegen`, `unity-devkit`) are PyPI dependencies of the dev group; github-actions-toolkit (the release/CI binding) is consumed only through `uses:` refs at a pinned full SHA, never installed or depended on (contract home: its `AGENTS.md`).

- `uv run install-zed` — end-to-end SSH deploy of the box stack (see `scripts/AGENTS.md`). `--build` cross-compiles images locally instead of pulling from ghcr.
- `uv run install --build --project CaptureTool` — build the APK and install it on the host-attached phone (the READ_LOGS grant is manual — see the app's AGENTS). `uv run build-unity --project CaptureTool --build AndroidMobile` for a build-only sanity check.
- `uv run build --targets zed-capture --targets aoa-bridge --targets aoa-gateway` — bake the arm64 box images per the root `docker-devkit.yaml` build declarations, `repository` + `base_images` + `platforms` (docker-devkit; `--push` is the CI shape). Needs QEMU + buildx on non-arm64 hosts.
- `uv run openapi-client-codegen --config openapi-client-codegen.yaml` — regenerate the zed-capture C# client from the service's OpenAPI spec. Needs Java 11+ on PATH.
- `uv run preflight-python` — the full check battery CI runs (sync, ruff, basedpyright, deptry, lock checks, pytest). CI's preflight job runs it then `uv run openapi-client-codegen --config openapi-client-codegen.yaml --check` (the staleness gate — regenerates and fails if the spec or generated client differs from the committed tree).
- Quick checks: `uv run ruff check .`, `uv run basedpyright`, `uv run pytest` (zed tests run against the stub; no camera needed).

**Codegen commit hygiene**: regenerated artifacts under `packages/generated/` and `workloads/zed-capture/openapi.json` live in their own dedicated commit, message exactly `Run generate-clients` — no body, no rationale.

## Branches and release

`main` = release (default branch), `dev` = working. Four workflow files split by triggering event (contract home: github-actions-toolkit's `AGENTS.md`). `integrate.yml` (PR to `dev` + dispatch) composes the toolkit's reusables: `mirror-images` → `preflight` → `build-unity` ∥ `build-docker` → `release-pr-builds`. The unity legs run `build-unity` inside `unityci/editor` containers on hosted runners, version-stamped by the binding's matrix verb; the docker legs fan out per docker-devkit's `docker-build-matrix`, each leg shelving its own digest-manifest shard; `preflight` runs `lint-workflows`, `validate-release-plan`, and `scripts/preflight.py` (the python battery, then the openapi-client staleness gate). `release.yml` (push to `main`/`dev`, concurrency queues without cancel) delivers via the release composite: `channel: dev` cuts the `dev-{count}` published prerelease (app builds + built-image table) — no packages publish, the zed-capture client is intra-repo — and `channel: stable` cuts the CalVer CaptureTool release with the APK and image table pulled from the ghcr builds shelf, then sweeps the `dev-*` releases. `merge-gate.yml` is the bors-model lander, woken only by the `ready-to-merge` label; its merge sweeps the PR's `pr-{N}-*` releases and promotes the landed PR's unity-library cache onto the dev tag (the gate job carries `packages: write` for the promotion — the merge-bot App holds no packages grant). `cleanup-pr-releases.yml` (PR closed unmerged) removes an abandoned PR's releases. The devkits are PyPI dependencies, so their verbs run inline as `uv run` against the synced workspace, version-sourced by `uv.lock`.

## Contracts

| Contract | Boundary | Home |
|---|---|---|
| Capture tar (`rig*/frames.csv` + stereo JPEGs + factory calibration) | box → placeframe reconstructor, **cross-repo** | wire types in `placeframe-core` (PyPI) |
| zed-capture REST API | box → phone, field-deploy; committed `openapi.json` is the compat gate | this repo (spec + generated client) |
| AOA transport (h2c prior-knowledge over accessory FD → 127.0.0.1:9000) | phone ↔ box, field-deploy | this repo (`workloads/aoa-bridge` + phone handler) |
| Log drain (box-clock semantics, restamp at push boundary) | box → phone intra-repo; ingestion edge **cross-repo** | split: box-clock/restamp here; ingestion edge in placeframe |

**Compat policy (paired versions)**: a change to any shared surface (zed-capture API, AOA transport, log-drain semantics) ships phone and box together as a matched pair; mismatches are unsupported, not engineered against, and there is no additive-only CI gate. Phone-only changes never require a box update. One authoritative home per contract, referenced — never duplicated — by subsystem docs.

## Workspace shape

`uv` workspace: `workloads/zed-capture` (service `zed`), `workloads/aoa-bridge`, `scripts`. `zed` exact-pins `placeframe-common`/`placeframe-core` from PyPI; repin deliberately (both, same run id). No `[tool.uv.sources]` beyond the local `scripts` member: every dependency resolves from PyPI, which is the point of the extraction.

Box observability (loki/alloy) consumes **stock mirror images** declared in the root `docker-devkit.yaml` `base_images` as upstream-native refs (`LOKI_IMAGE`/`ALLOY_IMAGE`; docker-devkit derives the org-mirror spelling by prefix injection from the default mirror prefix) and pinned via `docker-devkit.lock` (`NAME=mirror-ref@sha256:…`, regenerated by `uv run build --lock-only`), mounted with compose `configs:` — no wrapper images exist here. The service set and bake targets derive from the `workloads/` Dockerfile tree; no bake manifest exists. The mirror namespace is org-shared; CI's `mirror-images` job (docker-devkit's `mirror` verb) populates it from the same declarations before every build. `docker-devkit.lock` carries the `merge=ours` git attribute.

## Sandbox notes (COI)

- Toolchain uv may predate the repo pin (0.12.15): use `~/.local/bin/uv` and invoke venv entry points as `env -u UV_PYTHON PATH="$HOME/.local/bin:$PATH" .venv/bin/<cmd>`. Capture exit codes explicitly; never pipe through `tail`.
- **No pushes from the sandbox** — the App token is read/PR-write only. Commit locally, hand branch + SHA to the operator.
- Never `gh run watch` (rate limit); single `gh run view` calls with manual waits.
- Java (JDK 11+) must be on PATH for codegen — `sudo apt-get install -y default-jre-headless` if the spec dump stage fails.
- `docker compose` for the rig is only ever rendered (`docker compose config` in a scratch dir) — never `up`'d from the repo; the box is deployed exclusively via `install-zed`.

## Subsystem docs

- `apps/CaptureTool/AGENTS.md` — the phone app, AOA HTTP path, Unity invocation.
- `workloads/zed-capture/AGENTS.md` — the capture service actor, box constraints, `frames.csv` schema.
- `workloads/aoa-bridge/AGENTS.md` — the USB accessory handshake daemon.
- `scripts/AGENTS.md` — `install-zed` and the box deploy constraints.
