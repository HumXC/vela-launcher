WebP lossless regression fixture from Google’s WebP sample gallery:

https://www.gstatic.com/webp/gallery3/1_webp_ll.webp

Used offline to exercise lossless SIMD predictors during concurrent decoder startup. Tests compare complete decoded pixel hashes across all workers and repeated decodes.
