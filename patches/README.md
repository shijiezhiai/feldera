# patches/

Edits to upstream Feldera files that we carry as patch files instead of ordinary commits. Applied
after a rebase by `scripts/apply-patches.sh`; the policy (size cap, header format, generation) is in
`docs/upstream-sync.md` §2.

**The stack is currently empty.** The nine upstream files we edit are ordinary commits on the
working branches; extraction candidates and their triggers are recorded in §2 of that document.

Conventions, in short:

* `NNNN-kebab-name.patch`, four digits, strictly increasing, never reused.
* At most 2 000 changed lines; larger means split it or turn it into a new file plus a one-line
  include (bucket A in the policy doc).
* One logical change per patch.
* Header above the diff:

  ```text
  Upstream-Ref: feldera@<tag> (<sha>)
  Reason: <why we cannot wait for upstream>
  Conflicts: <files/functions where upstream churn is expected>
  Upstream-PR: <link, or "none planned">
  ```

* No generated files: `Cargo.lock`, `webconsole-dist/`, build output.

Apply or dry-run:

```bash
scripts/apply-patches.sh --check   # dry run, verifies every patch still applies
scripts/apply-patches.sh           # apply in number order
```
