-- The application supports a forecast based on the previous completed period
-- for an active next period. Keep the database constraint aligned with the API.
alter table public.predictions
  drop constraint if exists predictions_forecast_level_check;

alter table public.predictions
  add constraint predictions_forecast_level_check
  check (forecast_level in ('period','next_period','year','program'));
