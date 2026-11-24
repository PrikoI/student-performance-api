alter table public.user_preferences
  drop constraint if exists user_preferences_language_check;

alter table public.user_preferences
  add constraint user_preferences_language_check
  check (language = any (array['en'::text, 'ru'::text, 'kk'::text, 'zh'::text, 'es'::text]));

