"""Archived email delivery implementation.

This module is intentionally not imported by the active application.
It preserves the former Resend integration for a future verified-domain rollout.
"""

import asyncio
import os
import httpx
from fastapi import HTTPException


async def send_resend_email(email, subject, html, idempotency_key):
    key = os.getenv("RESEND_API_KEY")
    if not key:
        raise HTTPException(503, "Email delivery is not configured.")
    headers = {
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
        "Idempotency-Key": str(idempotency_key)[:256],
    }
    payload = {
        "from": os.getenv("MAIL_FROM", "Perfecta <onboarding@resend.dev>"),
        "to": [email],
        "subject": subject,
        "html": html,
    }
    async with httpx.AsyncClient(timeout=20, follow_redirects=False) as client:
        for attempt in range(3):
            try:
                response = await client.post(
                    "https://api.resend.com/emails", headers=headers, json=payload
                )
            except (httpx.TimeoutException, httpx.NetworkError):
                if attempt == 2:
                    raise HTTPException(502, "Email service temporarily unavailable")
                await asyncio.sleep(2**attempt)
                continue
            if not response.is_error:
                return response.json().get("id")
            if response.status_code not in (429, 500, 502, 503, 504) or attempt == 2:
                break
            await asyncio.sleep(2**attempt)
    raise HTTPException(502, "Email provider rejected the message")


async def send_auth_email(email, code, purpose, challenge_id):
    title = "Подтверждение регистрации" if purpose == "registration" else "Сброс пароля"
    action = "завершения регистрации" if purpose == "registration" else "сброса пароля"
    html = (
        f"<h2>{title}</h2><p>Код для {action}:</p>"
        f"<p style='font-size:28px;font-weight:700;letter-spacing:6px'>{code}</p>"
        "<p>Код действует 10 минут. Если запрос делали не вы, проигнорируйте письмо.</p>"
    )
    return await send_resend_email(email, title, html, f"{purpose}-{challenge_id}")
