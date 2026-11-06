# Student Performance API

FastAPI backend for the Student Performance prototype. Existing Supabase is the persistent store.
No student data or credentials are committed. Figma is not modified by this repository.

## Run
Python 3.12. Install requirements.txt and run:
`uvicorn app.main:app --host 0.0.0.0 --port 8000`
Set SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, AI_ENCRYPTION_KEY and CORS_ORIGINS.
AI_ENCRYPTION_KEY is a persistent Fernet key, kept in Render secrets, not source control.
Interactive API: /docs. Administrator AI settings UI: /admin. Health: /health.
Render start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`.

## Authentication and ownership
POST /auth/register: {email,password,full_name}. POST /auth/login: {email,password}.
Both return session_token, student_id, account_id. Send Authorization: Bearer <session_token>.
POST /auth/logout invalidates the token. GET /me returns role and identity.
The token is the existing seven-day opaque prototype session, not a Supabase Auth JWT.
The server never accepts a student_id to expand an ordinary user's read scope.
No password/email confirmation is required. Password hashes live in a private table.
Do not expose the old direct Supabase RPC login to a production frontend without equivalent rate limits.

## Records
GET /data: complete personal academic dataset.
GET /tables/{entity}?q=&period_id=&offset=0&limit=50: personal search, limit <=100.
POST /tables/{entity}: {data:{...}}. Omit the PK to insert; include it to update owned data.
PATCH /tables/{entity}/{id}: {data:{...}}.
DELETE /tables/{entity}/{id}?confirm=true: owned deletion, blocked for students/predictions/recommendations; referenced parent deletion is rejected.
POST /courses: {name}.
POST /records/batch: {records:[{entity,data},...]}, <=100 records, atomic.
Create parent records first and use returned IDs. Batch data cannot reference not-yet-generated IDs.
Supported writable entities: study_programs, academic_years, academic_periods, academic_settings, academic_performance, lesson_attendance, assessment_components, assessments, assessment_results, actual_results, notifications, academic_import_drafts, grading_scales.
Historical academic settings used by a period remain immutable: insert a new version.
POST /tables/students edits full_name/group_name; POST /tables/user_preferences edits language/display_mode/accent_color. GET /preferences reads preferences. POST /tables/grading_bands creates/updates an owned scale band; PATCH /tables/courses/{id} renames a personally owned course. Shared seed courses cannot be renamed.
Predictions are written using /predict with save=true, not generic record updates.

## Demonstration administration
GET /admin/tables/{entity}?student_id=2&q=&offset=0&limit=50.
Admin-only read/search of whitelisted public academic tables, courses, accounts, prediction_details and grading_bands.
No arbitrary SQL/table names, passwords, session hashes or private credentials are returned.
Admin AI uses the same PERSONAL scope as any student; it has no cross-student tools.

## Calculator (no AI provider needed)
POST /calculate:
{calendar:"trimester",items:[{grade:82,credits:5},{grade:94,credits:3}],bands:[]}
Or select exactly one period_id, year_id or program_id. Saved records supply grades/credits; final grades take priority when present.
overrides maps performance_id to replacement grade/credits; items can append manual rows.
The operation does not save any overrides. Missing grades/credits must be supplied.
Custom score_min/score_max are supported for manual input.
GPA is credit-weighted AFTER converting each subject, not by converting the overall average.
No conversion rule -> gpa:null with an explanation.
Calendar controls saved-context validation; grade computation follows explicit weights, not an invented universal trimester formula.

## Predictions
POST /predict: {period_id:...,level:"period"|"year"|"program",save:false}.
Only an active current period; no future start date or elapsed end date.
period: current subject grades + small recent-assessment signal; optional midterm/final component estimates.
year: configured annual period count required; observed current period + completed periods must cover >=2/3. Completed periods need actual final grades.
program: year rules + known duration + actual outcomes covering >=2/3 completed program years (at least one).
Historical grading contexts must match or the call rejects with an explicit-conversion requirement.
Saved results and original subject inputs are stored as snapshots.
This is an UNVALIDATED transparent baseline, not trained ML. Future workloads/credits are assumed comparable.
Attendance and assignment counts are preserved as context, not given unsupported causal coefficients.
Exam estimates use the same course-scale baseline and are explicitly labelled as such.
Numeric forecasts work without an LLM key. The assistant invokes this exact function.
See docs/forecast-method.md.

## AI setup and multiple requests
PUT /admin/ai: {base_url,model,api_key,enabled}. GET only returns key_configured, never the encrypted or plaintext key.
The /admin page provides a password-type key field. Leave api_key absent to retain the old key.
Key ciphertext persists in Supabase; the encryption key stays in Render.
Providers must implement Chat Completions. HTTPS and approved public hosts only.
AI_ALLOWED_HOSTS defaults to api.openai.com, openrouter.ai, api.groq.com, generativelanguage.googleapis.com.
A model may reject a compatible request; no provider was selected and no paid AI calls were made during development.
POST /ai/chat: {message}. At most 5 validated operations, sequentially.
Allowed operations are personal read, personal write proposal, calculator, forecast, textual answer.
At the first write, later operations wait. Response contains proposed_actions and confirmation_token.
Show the exact actions to the user; POST /ai/execute {confirmation_token} after approval.
Plans expire after 5 minutes and are account-bound; no model replanning during execution.
Failure stops dependent subsequent actions and reports them as skipped.
The model never receives session tokens, credential tables, names/emails from the students table, or admin-wide records.
Academic free-text fields can still contain personal information; users should know their selected provider processes the submitted academic context.
Configured limits: <=6000 message characters, <=50000 context characters, 2500 output tokens, 40s provider timeout, 90s request deadline.
10 AI requests/hour/account, 120 normal requests/minute/session, 10 logins/minute/IP, 5 registrations/hour/IP.
Limits and plan replay cache are per process; use one worker for this demo. They reset on restart. Production needs a distributed persistent limiter/replay store.
Direct Supabase prototype RPCs are separate from Render's HTTP limits.
LLM writes require confirmation; no arbitrary SQL, external URLs, deletion or admin tools are exposed to the model.

## Verification
python -m unittest discover -v
Local unit/API tests plus live Supabase login/admin-read/logout checks.
Database changes in database/api.sql were already applied to the designated project.
No frontend integration, predictive accuracy evaluation, recovery UI or production hardening is claimed.

