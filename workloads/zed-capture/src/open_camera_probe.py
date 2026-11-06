# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false, reportUnknownVariableType=false, reportIndexIssue=false
from pyzed import sl  # pyright: ignore[reportMissingModuleSource]

from .zed.zed_wrapper import build_init_parameters


def main() -> int:
    camera = sl.Camera()
    error = camera.open(build_init_parameters())
    camera.close()
    return 0 if error == sl.ERROR_CODE.SUCCESS else 1


if __name__ == "__main__":
    raise SystemExit(main())
