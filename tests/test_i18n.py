import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_HTML = (ROOT / "app" / "app.html").read_text(encoding="utf-8")
LANGUAGES = ("en", "ru", "kk", "zh", "es")
LOCALES = {
    language: json.loads((ROOT / "app" / "locales" / f"{language}.json").read_text(encoding="utf-8"))
    for language in LANGUAGES
}


def leaf_paths(value, prefix=""):
    paths = set()
    if isinstance(value, dict):
        for key, child in value.items():
            paths |= leaf_paths(child, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            paths |= leaf_paths(child, f"{prefix}[{index}]")
    else:
        paths.add(prefix)
    return paths


class LocalizationTests(unittest.TestCase):
    def test_all_locales_have_identical_keys(self):
        expected = leaf_paths(LOCALES["en"])
        for language in LANGUAGES[1:]:
            self.assertEqual(expected, leaf_paths(LOCALES[language]), language)

    def test_critical_dialog_sections_are_externalized(self):
        required = {
            "auth", "agreement", "chat", "forecastPage", "forecastLoading",
            "forecastDetails", "forecastModal", "security", "common", "nav", "roles",
            "assistantForecast",
        }
        for language, locale in LOCALES.items():
            self.assertTrue(required <= locale.keys(), language)
            self.assertTrue(locale["forecastModal"]["title"], language)
            self.assertTrue(locale["forecastLoading"]["steps"], language)
            self.assertTrue(locale["agreement"]["sections"], language)

    def test_old_inline_translation_dictionaries_are_gone(self):
        forbidden = (
            "const translations=", "PAGE_TRANSLATIONS", "LANGUAGE_PROFILES",
            "POLISH_TRANSLATIONS", "ABOUT_TRANSLATIONS", "const FORECAST_UI={",
            "const FORECAST_FORM={",
        )
        for marker in forbidden:
            self.assertNotIn(marker, APP_HTML)

    def test_language_refresh_includes_dialogs(self):
        apply_language = re.search(r"function applyLanguage\(\)\{(.+?)\n", APP_HTML)
        self.assertIsNotNone(apply_language)
        body = apply_language.group(1)
        for selector in ("#app *", "#modal *", "#agreementGate *", "#auth *"):
            self.assertIn(selector, body)
        self.assertIn("applyDataI18n($('#modal'))", APP_HTML)

    def test_english_is_the_static_auth_source(self):
        self.assertIn('<h1 id="authTitle">Sign in</h1>', APP_HTML)
        self.assertNotIn('<h1 id="authTitle">Вход</h1>', APP_HTML)

    def test_locale_asset_version_was_bumped_with_locale_changes(self):
        self.assertIn("const LOCALE_ASSET_VERSION='2026-11-24-1'", APP_HTML)

    def test_legacy_text_is_normalized_before_translation(self):
        self.assertIn("function normalizeUiText(value)", APP_HTML)
        self.assertIn("const normalized=normalizeUiText(value)", APP_HTML)
        self.assertIn("defaultValue:normalizeUiText(button.textContent)", APP_HTML)

    def test_language_cycle_has_a_translation_for_every_calculator_phrase(self):
        english = LOCALES["en"]["uiPhrases"]
        for language in LANGUAGES:
            self.assertEqual(set(english), set(LOCALES[language]["uiPhrases"]), language)
        for source_language in ("ru", "zh", "es"):
            reverse = {value: key for key, value in LOCALES[source_language]["uiPhrases"].items()}
            for english_text, source_text in LOCALES[source_language]["uiPhrases"].items():
                self.assertEqual(english_text, reverse[source_text])
                self.assertTrue(LOCALES["en"]["uiPhrases"][english_text])
                self.assertTrue(LOCALES["zh"]["uiPhrases"][english_text])

    def test_dynamic_user_content_is_not_machine_translated(self):
        self.assertIn(".messages,.chat-session-list,.student-directory,.admin-student-details", APP_HTML)

    def test_brand_tagline_stays_stable_across_language_cycles(self):
        self.assertIn(".brand small,.dashboard-brand small", APP_HTML)
        self.assertIn("element.textContent='Student Performance'", APP_HTML)
        self.assertIn("element.closest('.brand,.dashboard-brand", APP_HTML)

    def test_database_accepts_every_supported_interface_language(self):
        migration = (ROOT / "database" / "support-all-interface-languages.sql").read_text(encoding="utf-8")
        for language in ("en", "ru", "kk", "zh", "es"):
            self.assertIn(f"'{language}'::text", migration)

    def test_language_cache_is_scoped_to_the_current_account(self):
        self.assertIn("`perfecta_language_${state.me.student_id}`", APP_HTML)
        self.assertIn("localStorage.setItem(languageCacheKey(),v)", APP_HTML)
        self.assertIn("const cachedLanguage=localStorage.getItem(languageCacheKey())", APP_HTML)

    def test_calculator_and_admin_chat_sources_are_english(self):
        calculator = APP_HTML.split("function calculator(){", 1)[1].split("function addCalcRow", 1)[0]
        admin_chats = APP_HTML.split("function adminChats(){", 1)[1].split("async function loadAdminChats", 1)[0]
        self.assertIsNone(re.search(r"[А-Яа-яЁё]", calculator))
        self.assertIsNone(re.search(r"[А-Яа-яЁё]", admin_chats))


if __name__ == "__main__":
    unittest.main()
