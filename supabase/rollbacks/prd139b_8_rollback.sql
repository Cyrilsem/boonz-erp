-- Rollback for 20261006063117_prd139b_8_dispatch_photos_bucket.sql
DROP POLICY IF EXISTS dispatch_photos_select ON storage.objects;
DROP POLICY IF EXISTS dispatch_photos_insert ON storage.objects;
DELETE FROM storage.buckets WHERE id = 'dispatch-photos';
