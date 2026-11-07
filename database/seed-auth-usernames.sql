-- Seed case-sensitive usernames and demo addresses for the existing project accounts.
update public.students set email='student'||student_id||'@example.com' where student_id between 1 and 8;
update private.account_credentials c set email='student'||s.student_id||'@example.com',username=case s.student_id when 1 then 'AizatBekova' when 2 then 'MansurNarbaev' when 3 then 'MadinaSauranbek' when 4 then 'FaridaKuanysh' when 5 then 'AskhatKlenov' when 6 then 'BirzhanSaukymov' when 7 then 'YersultanAlibekov' when 8 then 'DaurenSeitzhan' end,is_demo=true,password_reset_enabled=false,email_verified_at=now() from public.accounts a join public.students s on s.student_id=a.student_id where c.account_id=a.account_id and s.student_id between 1 and 8;
update private.account_credentials c set username='admin',is_demo=true,password_reset_enabled=false,email_verified_at=now() from public.accounts a where c.account_id=a.account_id and a.role='admin';
update private.account_credentials c set username='Prikol' from public.accounts a where c.account_id=a.account_id and a.student_id=15;
update private.account_credentials c set username='Madina' from public.accounts a where c.account_id=a.account_id and a.student_id=16;
update private.account_credentials c set username='Tamerlan' from public.accounts a where c.account_id=a.account_id and a.student_id=17;
alter table private.account_credentials alter column username set not null;
alter table private.account_credentials drop constraint if exists account_credentials_username_check;
alter table private.account_credentials add constraint account_credentials_username_check check(username ~ '^[A-Za-z][A-Za-z0-9_]{2,29}$');
