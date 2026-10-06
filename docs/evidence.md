# Verification evidence retention

`tools/ref/` is the pointer to the archived migration references, not the
archive itself. The removed tree contained 553 tracked files, about 80 MiB, and
is identified by `tools/ref/MANIFEST.sha256`. Keep historical screenshots in
external release/object storage when they need to outlive normal git history.

New runner logs, performance JSON, contact sheets and investigation screenshots
belong in an absolute temporary/output directory (`tools/check.py --log-dir`)
or ignored `tools/evidence/`. CI uploads a per-platform verification artifact.
These outputs record the source commit, engine, options and completeness; an
unlabeled screenshot is insufficient proof of a numerical or performance claim.

Promote a new long-lived visual baseline only when a test or document names its
purpose and regeneration command. Keep one current reference per distinct
behavior/pose/quality case. Replace superseded comparison output instead of
adding numbered checkpoints. A curated baseline change must explain the visual
difference in its commit; unchanged generated output should not be committed.

Review findings and concise measured results belong in the dated review log.
Physical derivations and lasting contracts belong in their topic documents.
Temporary machine-specific paths in historical review entries identify original
evidence but are not portable reproduction instructions.
