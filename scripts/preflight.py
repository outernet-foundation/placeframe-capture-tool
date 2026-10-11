from bashrun.bash import bash


def main() -> None:
    bash("uv run --locked preflight-python")
    bash("uv run --locked openapi-client-codegen --config openapi-client-codegen.yaml --check")


if __name__ == "__main__":
    main()
