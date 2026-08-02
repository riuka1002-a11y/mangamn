# MangaMN OAuth тохиргоо

## GitHub Pages URL

Site URL:

https://riuka1002-a11y.github.io/mangamn/

Redirect URL:

https://riuka1002-a11y.github.io/mangamn/**

Supabase callback URL:

https://dqxnwgryjxjvrhsvyfco.supabase.co/auth/v1/callback

## Supabase

Supabase Dashboard → Authentication → URL Configuration:

- Site URL: `https://riuka1002-a11y.github.io/mangamn/`
- Redirect URLs: `https://riuka1002-a11y.github.io/mangamn/**`

Supabase Dashboard → Authentication → Providers:

- Email: Enable
- Google: Client ID + Client Secret
- Azure: Client ID + Client Secret; request email scope
- Facebook: App ID + App Secret; email permission
- Apple: Services ID + generated Client Secret

Provider-ийн Client Secret-үүдийг GitHub файлд хэзээ ч оруулахгүй.
