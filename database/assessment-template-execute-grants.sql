-- Public RPC wrappers are SECURITY INVOKER, so their callers also need
-- EXECUTE on the private functions they delegate to. The private functions
-- validate the session token and administrator role where required.
grant execute on function private.assessment_template_list(text),
  private.assessment_template_save(text,jsonb),
  private.assessment_template_delete(text,bigint),
  private.personal_assessment_template_list(text),
  private.personal_assessment_template_save(text,jsonb)
to anon, authenticated;
