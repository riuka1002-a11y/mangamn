# MangaVerse — бүрэн ажиллагаатай манга платформ

Энэ төсөл нь GitHub Pages дээр байрлах frontend болон Supabase backend ашиглана. HTML, CSS, JavaScript интерфэйс нь GitHub дээр байна; хэрэглэгч, эрх, манга, бүлэг, уншлагын явц болон зургууд Supabase-д хадгалагдана.

## Одоогоор ажиллах боломжууд

- Уншигч имэйл/нууц үгээр бүртгүүлэх, нэвтрэх
- Урилгын кодоор орчуулагчийн эрх авах
- Орчуулагч манга үүсгэх, засах, нийтлэх, нуух, устгах
- Нүүр зураг болон нэг бүлгийн олон хуудсыг upload хийх
- Бүлэг нийтлэх/нуух/устгах
- Уншигч нийтлэгдсэн манга, бүлгийг босоо хэлбэрээр унших
- Манга хадгалах
- Уншсан хуудсаа автоматаар санах
- Гар утас, tablet, computer-д responsive
- PWA/service worker болон GitHub Actions deployment
- Supabase Row Level Security: орчуулагч зөвхөн өөрийн бүтээлийг өөрчилнө

## Яагаад зөвхөн HTML/CSS биш вэ?

Жинхэнэ нэвтрэлт, файл upload, өгөгдлийн сан, хэрэглэгчийн эрхийг зөвхөн HTML/CSS-ээр аюулгүй хийх боломжгүй. Энэ төсөл HTML/CSS/JavaScript frontend + Supabase backend ашигладаг тул GitHub Pages дээр байрласан ч бодитоор ажиллана.

## 1. Supabase төсөл үүсгэх

1. Supabase-д шинэ project үүсгэнэ.
2. `SQL Editor` хэсгийг нээнэ.
3. Энэ repository дахь `supabase.sql` файлын бүх кодыг хуулж `Run` дарна.
4. SQL амжилттай ажилласны дараа `Table Editor` хэсэгт хүснэгтүүд үүссэн байна.

## 2. Орчуулагчийн урилгын код солих

`supabase.sql` файлд анхны код:

```sql
CHANGE-ME-TRANSLATOR
```

Үүнийг ажиллуулахын өмнө өөр код болгоно. Эсвэл SQL Editor дээр дараахыг ажиллуулж шинэ код нэмнэ:

```sql
insert into public.translator_invites (code, max_uses)
values ('MANGA-TEAM-2026', 10);
```

`max_uses` нь тухайн кодыг хэдэн орчуулагч ашиглаж болохыг заана.

## 3. Supabase URL болон key оруулах

Supabase Dashboard → `Project Settings` → `API` хэсгээс:

- Project URL
- anon public key

гэсэн 2 утгыг аваад `config.js` файлд оруулна:

```js
window.APP_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJ..."
};
```

`anon public key` нь frontend-д ашиглах зориулалттай. `service_role key`-г хэзээ ч GitHub-д бүү оруул.

## 4. Authentication тохируулах

Supabase Dashboard → `Authentication` → `URL Configuration`:

- Site URL: GitHub Pages холбоос, жишээ нь `https://username.github.io/manga-site/`
- Redirect URLs: дээрх URL-ийг дахин нэмнэ

Хэрэглэгч бүртгүүлээд шууд нэвтрэх шаардлагатай бол `Authentication` → `Providers` → `Email` хэсэгт email confirmation-ийг унтрааж болно. Жинхэнэ public сайт дээр email confirmation-ийг асаалттай үлдээх нь зөв.

## 5. GitHub дээр байрлуулах

1. GitHub дээр шинэ repository үүсгэнэ.
2. Энэ хавтасны бүх файлыг repository-ийн үндсэн хэсэгт upload хийнэ.
3. Default branch-ийг `main` болгоно.
4. Repository → `Settings` → `Pages` → Source хэсгээс `GitHub Actions` сонгоно.
5. `Actions` хэсэгт deploy дууссаны дараа Pages URL гарна.
6. Pages URL-ээ Supabase Authentication-ийн Site URL болон Redirect URLs-д оруулна.

Командын мөр ашиглавал:

```bash
git init
git add .
git commit -m "Initial MangaVerse platform"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
git push -u origin main
```

## 6. Ашиглах дараалал

### Орчуулагч

1. `Бүртгүүлэх` сонгоно.
2. `Орчуулагч баг` сонгоно.
3. Урилгын код оруулна.
4. Нэвтэрсний дараа `Орчуулагчийн студи` цэс гарна.
5. `Шинэ манга` → нүүр зураг, нэр, тайлбар, төрөл оруулна.
6. `Удирдах` → бүлгийн дугаар, нэр, олон хуудасны зураг сонгоод upload хийнэ.
7. Манга болон бүлгийг хоёуланг нь `Нийтлэгдсэн` төлөвт оруулбал уншигчдад харагдана.

### Уншигч

1. `Уншигч` эрхээр бүртгүүлнэ.
2. Номын сангаас манга сонгоно.
3. Бүлэг нээж босоо хэлбэрээр уншина.
4. Зүрхэн товчоор хадгална.
5. Дахин нээхэд сүүлд уншсан хуудас руу очно.

## Файлын бүтэц

```text
index.html                 Үндсэн интерфэйс
styles.css                 Бүх дизайн, responsive layout
app.js                     Auth, database, upload, reader logic
config.js                  Supabase public тохиргоо
supabase.sql               Database + RLS + storage policies
manifest.webmanifest       PWA тохиргоо
sw.js                      Offline core cache
assets/logo.svg            Лого
.github/workflows/pages.yml GitHub Pages deploy
```

## Production-д заавал анхаарах зүйл

- Орчуулах болон нийтлэх контентын эрхээ хууль ёсоор авсан байх
- Supabase email confirmation болон CAPTCHA асаах
- Translator invite code-г олон нийтэд бүү тавих
- Хэт том зураг upload хийхээс өмнө WebP болгон шахах
- Supabase storage/database backup хийх
- Custom domain ашиглавал Supabase redirect URL-д нэмэх
- Төлбөр, subscription, админ moderation нэмэх бол сервер талын webhook/Edge Function шаардлагатай

## Локал тест

Файлыг шууд `file://` хэлбэрээр нээхийн оронд local server ажиллуулна:

```bash
python -m http.server 8080
```

Дараа нь `http://localhost:8080` нээнэ. Local URL-ээ Supabase Redirect URLs-д нэмнэ.
