from saydrop_server.config import Settings
from saydrop_server.storage import REVISION, migrate


def main():
    try:
        settings = Settings.load()
        migrate(settings.database_path)
    except Exception:
        raise SystemExit("Migration failed; check server configuration and single-process ownership.") from None
    print(f"Saydrop schema revision {REVISION:03d} ready.")


if __name__ == "__main__":
    main()
