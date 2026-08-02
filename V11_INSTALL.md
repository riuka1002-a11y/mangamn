# MangaMN v11 Stability & Security Pack

## What changed

- New chapter pages upload to a **private** `chapter-pages` Storage bucket.
- Readers receive 10-minute signed page URLs only after RLS checks membership/team access.
- New chapter uploads use `uploading -> ready` state, so partial uploads cannot be published.
- File uploads retry transient network/server errors up to 3 times.
- Chapter cleanup/delete is bucket-aware.
- Manga INSERT team RLS is repaired with a security-definer authorization helper.
- Service Worker uses network-first for HTML/config and stale-while-revalidate for JS/CSS.
- SQL source is organized under `supabase/migrations/`.

## Install order

1. Upload `index.html`, `app.js`, `sw.js`, and `supabase.sql` to GitHub.
2. In Supabase SQL Editor run **only** `V11_RUN_ONCE.sql` once.
3. Sign out and sign back in.
4. Clear the old Service Worker/site cache once.
5. Upload a test chapter and verify reading with a paid reader account.
6. Run `V11_HEALTH_CHECK.sql` for a diagnostic report.

## Important legacy note

Pages uploaded before v11 stay in the old public `manga-pages` bucket. New v11 uploads are private. To fully protect an old test chapter, delete it and upload it again after v11. This pack deliberately does not delete or move existing Storage objects automatically.

## Files that do not need replacement

- `config.js` unless your Supabase/project URL changed.
- `styles.css` because v11 does not change the visual design.
