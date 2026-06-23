"""
Stress test for MyReadings app (Locust).

Run via container (Python 3.14 has a gevent/ssl incompatibility):
  podman run --rm -p 8089:8089 -v ./stress:/stress:Z \
    docker.io/locustio/locust -f /stress/locustfile.py \
    --host https://myreadings-ui-myreadings-dev.apps.cluster-c4nqd.dyn.redhatworkshops.io

Then open http://localhost:8089 in your browser.

Environment variables (all optional, have defaults):
  KC_TOKEN_URL   - Keycloak token endpoint
  KC_CLIENT_ID   - OAuth client id (default: myreadings-client)
  KC_USERNAME    - Keycloak user  (default: drossi)
  KC_PASSWORD    - Keycloak password (default: drossi)
"""

import os
import random
import time

from locust import HttpUser, task, between, events


KC_TOKEN_URL = os.getenv(
    "KC_TOKEN_URL",
    "https://myreadings-keycloak-myreadings-dev.apps.cluster-c4nqd.dyn.redhatworkshops.io"
    "/realms/my-readings/protocol/openid-connect/token",
)
KC_CLIENT_ID = os.getenv("KC_CLIENT_ID", "myreadings-client")
KC_USERNAME = os.getenv("KC_USERNAME", "drossi")
KC_PASSWORD = os.getenv("KC_PASSWORD", "drossi")

SEARCH_TERMS = [
    "batman", "spider-man"
]


class MyReadingsUser(HttpUser):
    wait_time = between(1, 2)

    def on_start(self):
        self._fetch_token()

    def _fetch_token(self):
        import requests
        resp = requests.post(
            KC_TOKEN_URL,
            data={
                "grant_type": "password",
                "client_id": KC_CLIENT_ID,
                "username": KC_USERNAME,
                "password": KC_PASSWORD,
            },
            verify=False,
        )
        data = resp.json()
        if "access_token" not in data:
            raise RuntimeError(
                f"Auth failed: {data.get('error')} - {data.get('error_description')}"
            )
        self._token = data["access_token"]
        self._token_expiry = time.time() + data.get("expires_in", 300) - 30

    def _auth_headers(self):
        if time.time() > self._token_expiry:
            self._fetch_token()
        return {"Authorization": f"Bearer {self._token}"}

    @task(3)
    def search_books(self):
        term = random.choice(SEARCH_TERMS)
        self.client.get(
            f"/api/v1/books/search?query={term}&size=60",
            headers=self._auth_headers(),
            verify=False,
        )

    @task(1)
    def get_reading_lists(self):
        self.client.get(
            "/api/v1/readinglists",
            headers=self._auth_headers(),
            verify=False,
        )
