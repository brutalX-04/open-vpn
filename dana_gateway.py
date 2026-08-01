#!/usr/bin/env python3
# ============================================================
#  bot/dana_gateway.py — DANA Payment Gateway QR Code Module
# ============================================================

import hmac
import hashlib
import json
import time
import requests
from typing import Dict, Any, Tuple

class DanaPaymentGateway:
    def __init__(self, merchant_id: str = "", client_id: str = "", client_secret: str = "", env: str = "sandbox"):
        self.merchant_id = merchant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.env = env.lower()

        if self.env == "production":
            self.base_url = "https://api.dana.id"
        else:
            self.base_url = "https://api.sandbox.dana.id"

    def _generate_signature(self, path: str, timestamp: str, body_str: str) -> str:
        string_to_sign = f"POST|{path}|{timestamp}|{body_str}"
        signature = hmac.new(
            self.client_secret.encode('utf-8'),
            string_to_sign.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()
        return signature

    def create_order(self, inv_id: str, amount: int, title: str) -> Tuple[bool, Dict[str, Any]]:
        """
        Creates an order via DANA Payment Gateway API and returns QR Code string / payment URL.
        """
        if not self.merchant_id or not self.client_id or not self.client_secret:
            return False, {
                "error": "DANA Gateway belum dikonfigurasi. Isi merchant_id, client_id, dan client_secret."
            }

        path = "/v1.0/qr/generate.htm"
        url = f"{self.base_url}{path}"
        timestamp = str(int(time.time() * 1000))

        payload = {
            "head": {
                "version": "1.0",
                "function": "dana.payment.generateQr",
                "clientId": self.client_id,
                "reqTime": timestamp,
                "reqMsgId": inv_id
            },
            "body": {
                "merchantId": self.merchant_id,
                "partnerReferenceNo": inv_id,
                "amount": {
                    "value": f"{amount}.00",
                    "currency": "IDR"
                },
                "title": title,
                "validTime": "15" # 15 minutes validity
            }
        }

        body_str = json.dumps(payload)
        signature = self._generate_signature(path, timestamp, body_str)

        headers = {
            "Content-Type": "application/json",
            "X-CLIENT-KEY": self.client_id,
            "X-TIMESTAMP": timestamp,
            "X-SIGNATURE": signature
        }

        try:
            res = requests.post(url, headers=headers, json=payload, timeout=10)
            data = res.json()
            if res.status_code == 200 and data.get("head", {}).get("resultCode") == "SUCCESS":
                qr_val = data.get("body", {}).get("qrCode", data.get("body", {}).get("checkoutUrl", f"https://checkout.dana.id/pay/{inv_id}"))
                return True, {
                    "order_id": data.get("body", {}).get("orderId", inv_id),
                    "payment_url": data.get("body", {}).get("checkoutUrl", qr_val),
                    "qr_code": qr_val,
                    "amount": amount,
                    "status": "INITIATED"
                }
            else:
                return False, {"error": data.get("head", {}).get("resultMsg", "API Error")}
        except Exception as e:
            return False, {"error": str(e)}

    def check_order_status(self, inv_id: str, order_id: str = "") -> Tuple[bool, str]:
        if not self.merchant_id or not self.client_id or not self.client_secret:
            return False, "DANA Gateway belum dikonfigurasi"

        path = "/v1.0/debit/orderStatus.htm"
        url = f"{self.base_url}{path}"
        timestamp = str(int(time.time() * 1000))

        payload = {
            "head": {
                "version": "1.0",
                "function": "dana.payment.queryStatus",
                "clientId": self.client_id,
                "reqTime": timestamp,
                "reqMsgId": f"Q-{inv_id}"
            },
            "body": {
                "merchantId": self.merchant_id,
                "partnerReferenceNo": inv_id
            }
        }

        body_str = json.dumps(payload)
        signature = self._generate_signature(path, timestamp, body_str)

        headers = {
            "Content-Type": "application/json",
            "X-CLIENT-KEY": self.client_id,
            "X-TIMESTAMP": timestamp,
            "X-SIGNATURE": signature
        }

        try:
            res = requests.post(url, headers=headers, json=payload, timeout=10)
            data = res.json()
            result_code = data.get("body", {}).get("resultInfo", {}).get("resultStatus", "")
            if result_code == "S" or result_code == "SUCCESS":
                return True, "SUCCESS"
            return False, result_code or "PENDING"
        except Exception as e:
            return False, f"ERROR: {str(e)}"
