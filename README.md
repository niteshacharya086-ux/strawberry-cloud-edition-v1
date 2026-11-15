# Strawberry Strategic Planner — Cloud Edition v1

## What is included
- Your latest uploaded `index.html`, with the existing planner and OCR payload preserved.
- Supabase email/password authentication.
- Multi-guild workspace selection and guild-specific cloud saves.
- Guild registration requests and membership requests.
- Roles: `platform admin`, `guild_admin`, `planner`, `member`.
- Database Row Level Security (RLS), plus a database trigger preventing planners from changing the roster JSON.
- Member participation submissions.
- Existing offline localStorage save remains as a local fallback.

## Important status
This is a first cloud-integration build, not a claim of a fully audited production system. The existing planner's role-specific UI still needs a complete permission pass and live cross-guild security testing. RLS is the actual data boundary; never rely on hidden buttons alone. Do not put sensitive/private files in public storage. No storage bucket is created in this version.

## Setup
1. Create a new Supabase project.
2. In Supabase → SQL Editor, run `supabase/schema.sql`.
3. Sign up through the app once using the email you want as platform owner.
4. In Supabase → Authentication → Users, copy that account's UUID.
5. In SQL Editor, run (replace the UUID):
   `insert into public.platform_admins(user_id) values ('YOUR-AUTH-USER-UUID');`
6. Open `config.js` and set:
   - `STRAWBERRY_SUPABASE_URL` to the Project URL.
   - `STRAWBERRY_SUPABASE_ANON_KEY` to the anon/publishable key.
   Never use the `service_role` key or database password in browser files.
7. Upload the contents of this folder to your GitHub Pages repository root (the `index.html`, `cloud.js`, `config.js`, and `supabase` folder must be together).

## Creating a guild
- Platform owner: sign in, open the top-right `Panel`, create a guild, and optionally enter the first guild admin's Supabase Auth user UUID.
- Public registration: a signed-in user can submit a new guild request; only the platform owner can approve it.
- Existing guild access: users request access using the Guild ID; a guild admin approves them in the panel.

## Role notes
- `guild_admin`: full guild workspace control.
- `planner`: may save map/strategy workspace changes; roster-management controls are hidden and the database trigger rejects changes to `players` and `pool`.
- `member`: read-only planner view and may submit participation.
- Platform admin membership is managed directly in the protected `platform_admins` table, not from client-side profile metadata.

## Known limitations to fix before inviting all members
- Add explicit per-control UI permissions for every role (especially planner vs guild_admin).
- Add private Supabase Storage with guild-scoped path policies before enabling file uploads.
- Add audit logging triggers for workspace/membership changes.
- Test with two separate guilds and four separate accounts, including attempted cross-guild reads/writes and planner roster tampering.
- Configure independent backups and check current Supabase plan limits/pausing behavior. Free tiers do not guarantee always-on availability.
- The panel currently shows membership request UUIDs rather than personal profile details; add a safe profile display table if you want names/emails visible to guild admins.

## Security reminders
- No website can be promised 100% unhackable.
- Use individual accounts; shared `admin/admin` credentials are unsafe and make auditing impossible.
- Keep RLS enabled. Do not disable it to "fix" an access error.
- Do not publish database passwords, service-role keys, or secret keys.
