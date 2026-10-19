-- Dev seed for mail: the local domain. Production sets its own row.
insert into public.mail_domains (domain, is_default) values ('palm.test', true)
on conflict (domain) do nothing;
