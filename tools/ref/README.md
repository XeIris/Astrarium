# Archived migration references

The migration screenshot archive was removed from the working tree to keep normal
checkouts small. The removed archive contained 553 tracked files under
`tools/ref/` at source commit `2f338cd4e82d2d5f0a05e0c33e7aec8b000ecc07`,
about 80 MiB, and is identified by `MANIFEST.sha256`.

The cleanup produced an ignored local handoff tarball named
`tools/evidence/tools-ref-archive-2f338cd.tar.gz`. Upload that tarball to
long-term release/object storage if the historical visual evidence needs to
survive a future history rewrite.

Archive SHA-256:

`d56ff4330df01d3e16406ebe98ab6e8991239f85e5c4f8b5be72552dc8249497`

New evidence should go to an absolute output directory or ignored
`tools/evidence/`, not back here.
