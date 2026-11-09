# install-zed --build failure: buildx cache export not supported

`uv run install-zed --build` fails at the `boatyard build --push-to
localhost:5000` step with:

    ERROR: Cache export is not supported for the docker driver.
    Switch to a different driver, or turn on the containerd image store,
    and try again.

## Root cause

The sweep replaced install-zed's forked bake pipeline with `boatyard
build --push-to localhost:5000`. The old code called
`render_bake(config, push=False, ...)` — the `push=False` was deliberate,
with the comment: "push=False renders no registry cache refs: their home
is ghcr, which a deploy host reaches anonymously at best, and the --set
flags retarget every tag at the local registry anyway." It then ran
`docker buildx bake ... --push` with `--set` flags retargeting tags at
`localhost:5000`. The `--push` flag pushes built images; it does not
involve cache export. The bake file had no `cache_to`/`cache_from`
entries.

`boatyard build --push-to` sets `pushing = push or push_to is not None`
to `True` (`build.py:105`). When `pushing` is true, `run_build` adds
`cache_to`/`cache_from` entries to the bake file (`build.py:186-191`):

```python
if pushing:
    cache = f"{namespace}/build-cache"
    build["cache_to"] = [
        f"type=registry,ref={cache}:{target},mode=max,image-manifest=true,oci-mediatypes=true"
    ]
    build["cache_from"] = [f"type=registry,ref={cache}:{target}"]
```

For `--push-to localhost:5000`, `namespace = "localhost:5000"`
(`build.py:163`), so cache refs point at `localhost:5000/build-cache:*`.
The deploy host's default buildx driver is "docker" (uses the Docker
daemon directly), which does not support `type=registry` cache export.
Only the "docker-container" driver does. The old code never hit this
because `push=False` produced no cache refs.

## Key code

- `boatyard/src/boatyard/build.py:105` — `pushing = push or push_to is
  not None`
- `boatyard/src/boatyard/build.py:163` — `namespace = destination if
  destination is not None else config.repository`
- `boatyard/src/boatyard/build.py:186-191` — cache ref generation, gated
  on `pushing` (should be gated on `push` only — see fix)
- `placeframe-capture-tool/scripts/src/scripts/install_zed/box_install.py`
  — the `{BOATYARD_BIN} build --push-to localhost:{REGISTRY_PORT}
  {target_flags}` call
- Old `box_install.py` (pre-sweep, git history before commit `220a5c6`
  on `compose-bundles`) — `render_bake(config, push=False, ...)` + `--set`
  flags + `docker buildx bake ... --push`

## Fix

Gate cache refs on `push` (repository mode) only, not `push_to`. In
`build.py:186`, change `if pushing:` to `if push:`.

The closeout defines `--push-to` as the ad-hoc destination path
("`--push-to` never shelves — ad-hoc destination, capture-tool's flow").
Cache refs to an ad-hoc registry are not useful — the registry is
transient (install-zed starts it on demand, no persistence). The old
code's `push=False` was the right behavior for this use case. `--push`
(repository mode, CI) keeps cache refs — CI uses the docker-container
driver and the cache namespace is the repository's ghcr, which is the
intended cache home. Risk: low — `--push-to` is always ad-hoc, no
existing workflow depends on `--push-to` cache refs.

This is a boatyard-side fix (one line), requiring a new release and a
repin in placeframe-capture-tool.

## Secondary issue: crane install prompts for sudo

`run_build` calls `relock(config)` on every build (`build.py:160`) — the
"incremental lock write rides every building run" behavior. `relock`
installs crane unconditionally (the installer always runs so the pin, not
a preexisting binary, decides the version). On the host this prompts for
sudo (`[sudo] password for tyler:` in the log). The lock is already fresh
(the sweep relocked it), so the crane install is a no-op resolution that
nonetheless requires elevated privileges. Not blocking (the user entered
the password), but unexpected for a build verb.

## Quick workaround (unblocks the deploy now)

    docker buildx create --use --driver docker-container

Then re-run `uv run install-zed --build`. The docker-container driver
supports registry cache export, and the cache refs to
`localhost:5000/build-cache:*` are harmless (they write cache to the
local registry, which install-zed started). This does not fix the
underlying issue (cache refs to a transient registry are wasted work),
but it unblocks the deploy while the proper fix is prepared.
