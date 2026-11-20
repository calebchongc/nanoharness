# Contributing to Harness (NanoHarness)

Thanks for contributing to **Harness / NanoHarness**!

## Contributor License Agreement (Required)

Before any pull request can be accepted, you must read and agree to the
[Contributor Assignment and License Agreement (`CLA.md`)](CLA.md).

Under `CLA.md`, all contributions are **irrevocably assigned** to the repository's
Licensors (**Standard Harness Pte. Ltd.**, **Rach Pradhan**, and **Yu Xi Lim**,
jointly) and become part of `"Licensor Material"` governed by
[`LICENSE`](LICENSE) — including its Reserved Commercial & Cloud Rights, Covered
Companies Additional Term, and Modified AGPL-3.0 terms.

### How to agree

Open your pull request and post a comment containing this exact sentence:

```text
I have read the Contributor License Agreement (CLA.md) and I hereby irrevocably agree to its terms.
```

An automated GitHub Actions check verifies your comment, records your signature
once per GitHub account (for the current revision of `CLA.md`) on the
`cla-signatures` branch, and marks the `CLA` check as passing for your current
and future pull requests.

If you are contributing on behalf of an employer or organization, ensure you
have authority to bind it or email
[rach@standardharness.com](mailto:rach@standardharness.com).

## Pull Request Checklist

- Include **Before** and **After** screenshots in your pull request description
  using synthetic data (`scripts/issue-screenshot.sh <PR number> <images>`).
- Add a test that reproduces the fix or covers the new behavior.
- Check attribution before pushing:
  `python3 scripts/check-attribution.py --range origin/main..HEAD`.
