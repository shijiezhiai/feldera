-- Memberships whose role follows the user's identity-provider groups.
--
-- `group_role_maps` maps a group name to a role. A login carrying a mapped
-- group gets that role, and — unlike a role an admin set, or the role a first
-- login or a passive claim enrollment produced — it is rewritten on every
-- login. Removing someone from the group in the identity provider therefore
-- demotes them on their next token rather than needing an admin to notice.
--
-- Only a row recorded here follows the token. The origin column is what makes
-- that distinction, since the two cases are otherwise identical rows: a role
-- and a tenant. Adding a value to the CHECK is the whole migration.
ALTER TABLE tenant_membership DROP CONSTRAINT IF EXISTS tenant_membership_origin_check;
ALTER TABLE tenant_membership ADD CONSTRAINT tenant_membership_origin_check
    CHECK (origin IN ('claim', 'derived', 'api', 'group'));
