from logging import getLogger
from typing import Annotated

import typer
from docker_devkit.context_sha import compute_service_shas
from docker_devkit.documents import parse_bake
from docker_devkit.modes import parse_env_file
from bashrun.bash import bash
from placeframe_common.logging_config import configure_logging

from .box_install import install_box
from .constants import (
    BAKE_FILE,
    BOX_SSH_TARGET,
    ENV_LOCK_FILE,
    REPO_ROOT,
    SSH_KEY,
    SSH_KNOWN_HOSTS,
    SSH_STATE_DIR,
)

logger = getLogger(__name__)
app = typer.Typer()


@app.command()
def main(
    build: Annotated[
        bool,
        typer.Option("--build", help="Cross-compile box images locally instead of pulling from ghcr"),
    ] = False,
) -> None:
    configure_logging("install-zed", log_file_path=REPO_ROOT / ".placeframe" / "logs" / "install-zed.jsonl")
    logger.info("starting_install", extra={"target": BOX_SSH_TARGET, "build": build})
    service_shas = compute_service_shas(REPO_ROOT, parse_bake(BAKE_FILE))
    env_lock = parse_env_file(ENV_LOCK_FILE)

    SSH_STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    SSH_KNOWN_HOSTS.touch(exist_ok=True)
    if not SSH_KEY.exists():
        logger.info("generating_ssh_key", extra={"path": str(SSH_KEY)})
        bash(f'ssh-keygen -t ed25519 -N "" -f {SSH_KEY}')

    install_box(build, service_shas, env_lock)
