import os
import random
import urllib3

from locust import HttpUser, task, between

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

KC_TOKEN_URL = os.environ["KC_TOKEN_URL"]
KC_CLIENT_ID = os.environ.get("KC_CLIENT_ID", "myreadings-client")
KC_USERNAME = os.environ.get("KC_USERNAME", "testuser")
KC_PASSWORD = os.environ.get("KC_PASSWORD", "testuser")

SEARCH_TERMS = ["batman", "spider"]


class MyReadingsUser(HttpUser):
    wait_time = between(1, 3)

    def on_start(self):
        self._fetch_token()
        self.reading_list_ids = []
        self.book_ids = []

    def _fetch_token(self):
        resp = self.client.post(
            KC_TOKEN_URL,
            data={
                "grant_type": "password",
                "client_id": KC_CLIENT_ID,
                "username": KC_USERNAME,
                "password": KC_PASSWORD,
            },
            verify=False,
            name="keycloak/token",
        )
        if resp.status_code == 200:
            self.token = resp.json().get("access_token", "")
        else:
            self.token = ""

    def _headers(self):
        return {"Authorization": f"Bearer {self.token}"}

    # ---- search (hits catalog-service, triggers N+1 when broken) ----
    @task(3)
    def search_books(self):
        term = random.choice(SEARCH_TERMS)
        with self.client.get(
            f"/api/v1/books/search?query={term}&page=0&size=30",
            headers=self._headers(),
            verify=False,
            name="/api/v1/books/search",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                data = resp.json()
                items = data.get("content", data) if isinstance(data, dict) else data
                if isinstance(items, list):
                    for b in items:
                        bid = b.get("bookId")
                        if bid and bid not in self.book_ids:
                            self.book_ids.append(bid)
                    if len(self.book_ids) > 40:
                        self.book_ids = self.book_ids[:40]

    # ---- reading lists (hits readinglist-service, OOMKills when constrained) ----
    @task(3)
    def get_reading_lists(self):
        with self.client.get(
            "/api/v1/readinglists",
            headers=self._headers(),
            verify=False,
            name="/api/v1/readinglists",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                data = resp.json()
                if isinstance(data, list):
                    self.reading_list_ids = [
                        rl.get("readingListId", rl.get("id"))
                        for rl in data
                        if rl.get("readingListId") or rl.get("id")
                    ]

    # @task(2)
    # def browse_catalog(self):
    #     self.client.get(
    #         "/api/v1/books?page=0&size=20",
    #         headers=self._headers(),
    #         verify=False,
    #         name="/api/v1/books",
    #     )

    # ---- book detail + reviews (hits catalog + review-service) ----
    @task(1)
    def book_detail(self):
        if not self.book_ids:
            return
        book_id = random.choice(self.book_ids)
        self.client.get(
            f"/api/v1/reviews/books/{book_id}/stats",
            headers=self._headers(),
            verify=False,
            name="/api/v1/reviews/books/{bookId}/stats",
        )

    # ---- Refresh token periodically ----
    @task(1)
    def refresh_token(self):
        self._fetch_token()
