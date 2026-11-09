from logging import getLogger
from typing import Annotated

import typer
import yaml
from bashrun.bash import bash_output
from placeframe_common.logging_config import configure_logging

from .box_install import install_box
from .constants import (
    BOATYARD_BIN,
    BOX_SSH_TARGET,
    LOCK_FILE,
    REPO_ROOT,
    SSH_KEY,
    SSH_KNOWN_HOSTS,
    SSH_STATE_DIR,
    ZED_SERVICES,
    ZED_STOCK_IMAGES,
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
    service_names = [service.name for service in ZED_SERVICES]
    tree_tags = bash_output(f"{BOATYARD_BIN} tree-tags {' '.join(service_names)}").strip().splitlines()
    service_shas = {service.sha_key: tag for service, tag in zip(ZED_SERVICES, tree_tags)}
    lock = yaml.safe_load(LOCK_FILE.read_text(encoding="utf-8"))
    lock_entries = {
        image.image_env: lock["images"][image.image_env]["platforms"]["linux/arm64"] for image in ZED_STOCK_IMAGES
    }

    SSH_STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    SSH_KNOWN_HOSTS.touch(exist_ok=True)
    if not SSH_KEY.exists():
        logger.info("generating_ssh_key", extra={"path": str(SSH_KEY)})
        bash_output(f'ssh-keygen -t ed25519 -N "" -f {SSH_KEY}')

    install_box(build, service_shas, lock_entries)
