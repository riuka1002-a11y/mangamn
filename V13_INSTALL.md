# MangaVerse v13 суулгах

## GitHub дээр upload хийх
- index.html
- styles.css
- app.js
- v13.js
- sw.js
- 404.html
- architecture.html
- assets/mock-1.svg ... assets/mock-6.svg
- supabase.sql (repository documentation backup)

`config.js`-ийн Supabase URL/key-г солихгүй.

## Supabase
SQL Editor дээр `V13_RUN_ONCE.sql`-ийг нэг удаа ажиллуул.

## Cache
Deploy дараа F12 → Application → Service Workers → Unregister → Clear site data → Ctrl+F5.

## Контент хамгаалалтын бодит хязгаар
Web browser нь үйлдлийн системийн screenshot эсвэл screen recorder-ийг бүрэн хааж чаддаггүй. v13 нь:
- right click / drag / print shortcut хориглох,
- private signed URL,
- user/time watermark,
- tab hidden үед blur,
- image download UI-г арилгах
зэрэг саатуулах ба эх үүсвэр тогтоох хамгаалалт ашиглана.

## Cloudflare
Cloudflare Images/Worker watermark болон CDN нь тусдаа Cloudflare account/deployment шаарддаг. Кодын дараагийн шатанд Worker origin-г config.CDN_BASE_URL-аар холбоно.

## SEO
GitHub Pages дээр JS dynamic meta нь браузерт ажиллана. Facebook/Google crawler-д бүрэн SSR meta хэрэгтэй бол Cloudflare Pages/Worker эсвэл SSR framework рүү шилжинэ.
