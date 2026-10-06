-- PRD-139b Item 8: machine photos storage bucket.
--
-- Confirmed before writing this: storage.buckets has 0 rows, dispatch_photos has 0
-- rows, no storage.objects RLS policies exist at all. Private bucket, no public
-- URLs -- the FE must switch from getPublicUrl (silently returns a URL that 404s
-- once the bucket is private) to createSignedUrl.

INSERT INTO storage.buckets (id, name, public)
VALUES ('dispatch-photos', 'dispatch-photos', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY dispatch_photos_insert ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'dispatch-photos'
    AND EXISTS (
      SELECT 1 FROM user_profiles
      WHERE user_profiles.id = (SELECT auth.uid())
        AND user_profiles.role = ANY (ARRAY['field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager'])
    )
  );

CREATE POLICY dispatch_photos_select ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'dispatch-photos'
    AND EXISTS (
      SELECT 1 FROM user_profiles
      WHERE user_profiles.id = (SELECT auth.uid())
        AND user_profiles.role = ANY (ARRAY['field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager'])
    )
  );
