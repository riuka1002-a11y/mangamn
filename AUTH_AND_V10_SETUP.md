# MangaMN v10 тохиргоо

## 1. Supabase Auth URL Configuration

Authentication → URL Configuration

- Site URL: `https://riuka1002-a11y.github.io/mangamn/`
- Redirect URLs: `https://riuka1002-a11y.github.io/mangamn/`
- Нэмэлтээр: `https://riuka1002-a11y.github.io/mangamn/**`

`http://localhost:3000`-ийг Site URL-аас бүрэн солино.

## 2. Email Templates

Authentication → Email Templates

Confirm signup болон Reset password template-ийн товч/линк нь Supabase-ийн `{{ .ConfirmationURL }}` утгыг ашиглах ёстой. `http://localhost:3000` гэсэн хатуу бичсэн холбоос байвал устгана.

## 3. Database

SQL Editor дээр `supabase_patch_v10.sql`-ийг бүтнээр нь ажиллуулна.

## 4. GitHub

`index.html`, `styles.css`, `app.js`, `sw.js`, `config.js` файлыг upload/replace хийнэ. `assets` хавтсыг хэвээр үлдээнэ.

## 5. Cache

Deploy дууссаны дараа Ctrl+F5. Хуучин хувилбар байвал DevTools → Application → Service Workers → Unregister, Storage → Clear site data.

## Super Like

1 Super Like = 1,000₮. Одоогийн хувилбар банкны баримтаар гараар баталгаажина. Админ зөвшөөрсний дараа баг болон бүлгийн тоонд нэмэгдэнэ.
