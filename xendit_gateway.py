#!/usr/bin/env python3
"""Xendit Payments API v3 client for a single-use QRIS payment request."""

from typing import Any, Dict, Tuple

import requests


class XenditPaymentGateway:
    API_BASE_URL = "https://api.xendit.co"
    API_VERSION = "2024-11-11"

    def __init__(self, secret_key: str = "") -> None:
        self.secret_key = secret_key

    def _headers(self, idempotency_key: str = "") -> Dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "api-version": self.API_VERSION,
        }
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        return headers

    @staticmethod
    def _error(response: requests.Response) -> str:
        try:
            body = response.json()
            return body.get("message") or body.get("error_code") or str(body)
        except ValueError:
            return response.text or "Xendit API error"

    def create_order(self, reference_id: str, amount: int, title: str) -> Tuple[bool, Dict[str, Any]]:
        if not self.secret_key:
            return False, {"error": "Xendit Secret API Key belum dikonfigurasi."}

        payload = {
            "reference_id": reference_id,
            "type": "PAY",
            "country": "ID",
            "currency": "IDR",
            "request_amount": amount,
            "channel_code": "QRIS",
            "description": title,
            "metadata": {"invoice_id": reference_id},
        }
        try:
            response = requests.post(
                f"{self.API_BASE_URL}/v3/payment_requests",
                auth=(self.secret_key, ""),
                headers=self._headers(reference_id),
                json=payload,
                timeout=15,
            )
        except requests.RequestException as exc:
            return False, {"error": str(exc)}
        if response.status_code not in (200, 201):
            return False, {"error": self._error(response)}

        data = response.json()
        qr_string = next(
            (
                action.get("value")
                for action in data.get("actions", [])
                if action.get("type") == "PRESENT_TO_CUSTOMER"
                and action.get("descriptor") == "QR_STRING"
            ),
            "",
        )
        if not qr_string:
            return False, {"error": "Xendit tidak mengembalikan QRIS untuk pembayaran ini."}
        return True, {
            "order_id": data.get("payment_request_id", reference_id),
            "qr_code": qr_string,
            "status": data.get("status", "ACCEPTING_PAYMENTS"),
        }

    def check_order_status(self, payment_request_id: str) -> Tuple[bool, str]:
        if not self.secret_key:
            return False, "Xendit Secret API Key belum dikonfigurasi"
        try:
            response = requests.get(
                f"{self.API_BASE_URL}/v3/payment_requests/{payment_request_id}",
                auth=(self.secret_key, ""),
                headers=self._headers(),
                timeout=15,
            )
        except requests.RequestException as exc:
            return False, f"ERROR: {exc}"
        if response.status_code != 200:
            return False, self._error(response)
        return response.json().get("status") == "SUCCEEDED", response.json().get("status", "UNKNOWN")
