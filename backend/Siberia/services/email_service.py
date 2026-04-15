"""Async SMTP email sender — config via settings (SMTP_HOST/PORT/USER/PASSWORD/FROM/TLS)."""
import logging
import smtplib
import asyncio
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

from config import settings

logger = logging.getLogger("siberia.email")


def _send_sync(to: str, subject: str, body_html: str) -> None:
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = settings.SMTP_FROM
    msg["To"] = to
    msg.attach(MIMEText(body_html, "html"))

    if settings.SMTP_TLS:
        with smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT) as smtp:
            smtp.ehlo()
            smtp.starttls()
            if settings.SMTP_USER and settings.SMTP_PASSWORD:
                smtp.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
            smtp.sendmail(settings.SMTP_FROM, to, msg.as_string())
    else:
        with smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT) as smtp:
            if settings.SMTP_USER and settings.SMTP_PASSWORD:
                smtp.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
            smtp.sendmail(settings.SMTP_FROM, to, msg.as_string())


async def send_email(to: str, subject: str, body_html: str) -> None:
    loop = asyncio.get_event_loop()
    try:
        await loop.run_in_executor(None, _send_sync, to, subject, body_html)
    except Exception:
        logger.exception("Failed to send email to %s subject=%s", to, subject)


async def send_verification_code(to: str, code: str) -> None:
    subject = "Siberia — подтвердите email"
    body = f"""
    <h2>Подтверждение email</h2>
    <p>Ваш код подтверждения: <strong style="font-size:24px;letter-spacing:4px">{code}</strong></p>
    <p>Код действителен 15 минут.</p>
    <p>Если вы не регистрировались в Siberia — просто проигнорируйте это письмо.</p>
    """
    await send_email(to, subject, body)


async def send_new_device_alert(to: str, ip: str, user_agent: str) -> None:
    subject = "Siberia — вход с нового устройства"
    body = f"""
    <h2>Новый вход в аккаунт</h2>
    <p>Был выполнен вход в ваш аккаунт Siberia с нового устройства.</p>
    <ul>
        <li><b>IP-адрес:</b> {ip}</li>
        <li><b>Устройство:</b> {user_agent[:200] if user_agent else "неизвестно"}</li>
    </ul>
    <p>Если это были не вы — немедленно смените пароль и завершите все сессии.</p>
    """
    await send_email(to, subject, body)
