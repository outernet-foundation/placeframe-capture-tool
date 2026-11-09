# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false, reportUnknownVariableType=false, reportIndexIssue=false
from pyzed import sl  # pyright: ignore[reportMissingModuleSource]

from .zed.zed_wrapper import build_init_parameters, build_positional_tracking_parameters


def main() -> int:
    camera = sl.Camera()
    error = camera.open(build_init_parameters())
    if error != sl.ERROR_CODE.SUCCESS:
        camera.close()
        return 1
    tracking_error = camera.enable_positional_tracking(build_positional_tracking_parameters())
    camera.close()
    return 0 if tracking_error == sl.ERROR_CODE.SUCCESS else 1


if __name__ == "__main__":
    raise SystemExit(main())
