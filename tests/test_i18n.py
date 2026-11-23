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


if __name__ == "__main__":
    unittest.main()
