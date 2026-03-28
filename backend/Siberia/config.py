from pydantic_settings import BaseSettings
from pydantic import ConfigDict


class Settings(BaseSettings):
    model_config = ConfigDict(env_file=".env")

    DATABASE_URL: str

    SECRET_KEY: str
    ALGORITHM: str

    ACCESS_TOKEN_EXPIRE_DAYS: int
    REFRESH_TOKEN_EXPIRE_DAYS: int

    REDIS_URL: str = "redis://localhost:6379/0"
    DEBUG: bool = False

    # "development" | "production" — если "production" и CORS_ORIGINS=="*" → процесс не стартует
    ENV: str = "development"

    # ── Auth tunables (вынесены из hardcoded констант) ────────────────────────
    MAX_SESSIONS: int = 5
    VERIFY_CODE_TTL_MINUTES: int = 15
    VERIFY_CODE_MAX_ATTEMPTS: int = 5      # попыток ввода email-кода
    VERIFY_CODE_LOCKOUT_MINUTES: int = 15  # на сколько блокируем после превышения

    # ── WebSocket tunables ────────────────────────────────────────────────────
    WS_PING_INTERVAL: int = 25
    WS_PING_TIMEOUT: int = 10

    # CORS: "*" для dev, "https://app.example.com" для prod (через запятую если несколько)
    CORS_ORIGINS: str = "*"

    # ── APNs (iOS push) ───────────────────────────────────────────────────────
    # Путь к .p8 файлу из Apple Developer → Keys
    APNS_KEY_PATH: str = ""
    # 10-символьный ID ключа (из Apple Developer)
    APNS_KEY_ID: str = ""
    # 10-символьный Team ID (из Apple Developer аккаунта)
    APNS_TEAM_ID: str = ""
    # Bundle ID приложения, например com.example.siberia
    APNS_BUNDLE_ID: str = ""
    # True = sandbox (TestFlight/Simulator), False = production
    APNS_SANDBOX: bool = True

    # ── FCM (Android push) ────────────────────────────────────────────────────
    # Legacy Server Key из Firebase Console → Project Settings → Cloud Messaging
    FCM_SERVER_KEY: str = ""

    # ── S3-compatible object storage (Cloudflare R2 / AWS S3) ────────────────
    S3_BUCKET: str = ""
    # Endpoint URL: "" = AWS default, "https://<account>.r2.cloudflarestorage.com" for R2
    S3_ENDPOINT: str = ""
    S3_KEY_ID: str = ""
    S3_SECRET: str = ""
    S3_REGION: str = "auto"
    # Public URL for presigned links (e.g. http://192.168.1.134:9000 for local MinIO).
    # If set, replaces S3_ENDPOINT host in generated presigned URLs so mobile clients can reach storage.
    S3_PUBLIC_URL: str = ""

    # ── SMTP (email verification / alerts) ───────────────────────────────────
    SMTP_HOST: str = "localhost"
    SMTP_PORT: int = 587
    SMTP_USER: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM: str = "noreply@siberia.app"
    SMTP_TLS: bool = True


settings = Settings()
