# Verification evidence retention

`tools/ref/` is the frozen migration reference archive: 553 tracked images,
78.90 MiB at closure review. It contains source references, comparisons and
historical investigation captures. It is excluded from game exports. Keep this
archive for interpreting the port's existing evidence rather than using it as
the destination for each new test run.

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
