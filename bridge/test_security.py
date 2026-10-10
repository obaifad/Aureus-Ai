import logging
import unittest

from security import (
    AuthThrottle,
    RedactSecretsFilter,
    is_loopback,
    keys_match,
    redact,
    validate_startup,
)

STRONG = "k" * 32


class KeyComparison(unittest.TestCase):
    def test_matches_only_identical_keys(self):
        self.assertTrue(keys_match(STRONG, STRONG))
        self.assertFalse(keys_match(STRONG + "x", STRONG))
        self.assertFalse(keys_match(STRONG[:-1], STRONG))

    def test_a_missing_key_never_matches_even_an_empty_expected_one(self):
        self.assertFalse(keys_match(None, STRONG))
        self.assertFalse(keys_match("", STRONG))
        self.assertFalse(keys_match("", ""))
        self.assertFalse(keys_match("anything", ""))

    def test_non_ascii_keys_do_not_crash(self):
        self.assertFalse(keys_match("é" * 20, STRONG))
        self.assertTrue(keys_match("é" * 20, "é" * 20))


class Loopback(unittest.TestCase):
    def test_loopback_addresses(self):
        for host in ("127.0.0.1", "127.5.5.5", "::1", "localhost"):
            self.assertTrue(is_loopback(host), host)

    def test_everything_else_is_exposed(self):
        for host in ("0.0.0.0", "::", "192.168.1.20", "10.0.0.5", "example.com", ""):
            self.assertFalse(is_loopback(host), host)


class StartupValidation(unittest.TestCase):
    def test_a_strong_key_on_loopback_is_fine(self):
        self.assertEqual(validate_startup("127.0.0.1", STRONG), [])

    def test_no_key_refuses_to_start_and_explains_how_to_make_one(self):
        (problem,) = validate_startup("127.0.0.1", "")
        self.assertIn("BRIDGE_API_KEY is not set", problem)
        self.assertIn("secrets.token_urlsafe", problem)

    def test_a_short_key_is_refused_everywhere(self):
        self.assertTrue(validate_startup("127.0.0.1", "short"))

    def test_exposing_the_bridge_needs_a_longer_key(self):
        medium = "m" * 18
        self.assertEqual(validate_startup("127.0.0.1", medium), [])
        problems = validate_startup("0.0.0.0", medium)
        self.assertTrue(any("exposes the bridge" in p for p in problems))
        self.assertEqual(validate_startup("0.0.0.0", STRONG), [])

    def test_no_key_on_a_public_bind_reports_only_the_missing_key(self):
        problems = validate_startup("0.0.0.0", "")
        self.assertEqual(len(problems), 1)


class Throttle(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.throttle = AuthThrottle(failures=3, window=60, block=300, clock=lambda: self.now)

    def test_blocks_after_the_configured_number_of_failures(self):
        self.assertFalse(self.throttle.record_failure("a"))
        self.assertFalse(self.throttle.record_failure("a"))
        self.assertTrue(self.throttle.record_failure("a"))
        self.assertTrue(self.throttle.is_blocked("a"))

    def test_other_clients_are_unaffected(self):
        for _ in range(3):
            self.throttle.record_failure("attacker")
        self.assertTrue(self.throttle.is_blocked("attacker"))
        self.assertFalse(self.throttle.is_blocked("owner"))

    def test_failures_spread_beyond_the_window_do_not_add_up(self):
        self.throttle.record_failure("a")
        self.now += 61
        self.throttle.record_failure("a")
        self.now += 61
        self.assertFalse(self.throttle.record_failure("a"))
        self.assertFalse(self.throttle.is_blocked("a"))

    def test_the_block_expires(self):
        for _ in range(3):
            self.throttle.record_failure("a")
        self.now += 299
        self.assertTrue(self.throttle.is_blocked("a"))
        self.now += 2
        self.assertFalse(self.throttle.is_blocked("a"))

    def test_a_success_clears_the_failure_count(self):
        self.throttle.record_failure("a")
        self.throttle.record_failure("a")
        self.throttle.record_success("a")
        self.assertFalse(self.throttle.record_failure("a"))


class Redaction(unittest.TestCase):
    def test_removes_keys_from_urls_and_headers(self):
        self.assertEqual(redact("GET /x?symbol=A&api_key=SECRET123&n=1"), "GET /x?symbol=A&api_key=***&n=1")
        self.assertNotIn("SECRET123", redact("headers {'x-api-key': 'SECRET123'}"))
        self.assertNotIn("SECRET123", redact('X-API-Key: SECRET123'))

    def test_removes_telegram_tokens(self):
        url = "POST https://api.telegram.org/bot123456789:ABCdefGHIjklMNOpqrSTUvwxYZ_0123456789/sendMessage"
        self.assertNotIn("ABCdef", redact(url))
        self.assertIn("sendMessage", redact(url))

    def test_leaves_ordinary_text_alone(self):
        text = "Order opened: ticket=5 buy 0.5 lots @ 2000.1"
        self.assertEqual(redact(text), text)

    def test_the_logging_filter_scrubs_formatted_messages(self):
        records = []

        class Capture(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage())

        logger = logging.getLogger("test_security_redaction")
        logger.setLevel(logging.INFO)
        logger.propagate = False
        logger.addFilter(RedactSecretsFilter())
        logger.addHandler(Capture())
        logger.info('%s - "WebSocket %s"', "127.0.0.1:1", "/stream/ticks?symbol=X&api_key=TOPSECRET")
        self.assertEqual(len(records), 1)
        self.assertNotIn("TOPSECRET", records[0])
        self.assertIn("api_key=***", records[0])


if __name__ == "__main__":
    unittest.main()
