# F Prime on QNX handoff

- Start with [README](README.md) and the [project plan](docs/zh/專案規劃書.md). Check the commit, branch, and V1/V2/V2b status in the [implementation log](docs/zh/實作迭代紀錄.md).
- For each implementation iteration, append the objective, changed files, attempts and errors, execution environment, commands, observed results, and the next action. Reference the commit and evidence paths when available.
- Append changes in direction or design trade-offs to the [decision log](docs/zh/決策與變更紀錄.md). Record the rationale, alternatives considered, consequences, and unresolved verification. Reference the decision ID from the implementation log.
- Record QNX target results with the SDK, architecture, and source revisions. Keep unsupported or skipped coverage visible. Store credentials, generated VM images, and full local tool transcripts outside the repository.
- When updating the project knowledge base, link the implementation and decision records, append a dated ingest entry, and pin imported source documents to the full commit SHA.
- Before a long QEMU session under WSL2, check that the libvirt `default` network is active. If you keep the WSL distribution resident for that work (for example with `instanceIdleTimeout` in `.wslconfig`) or leave a keep-alive process running, restore the previous setting or stop the process afterwards, because it keeps using memory and CPU while idle.

## Upstream contributions to nasa/fprime

The project owner posts every upstream issue, discussion, comment and pull request from their own account. Agents draft and verify; they do not post. [Upstream status](docs/en/upstream.md) · [D76](docs/zh/決策與變更紀錄.md#d76--keep-u3-as-a-local-finding-2026-11-25) · [D77](docs/zh/決策與變更紀錄.md#d77--report-u1-as-one-issue-and-prepare-fixes-only-locally-2026-11-25)

- Before drafting any post, confirm four things: the problem reproduces on the latest `devel`, it is not an intended design (read recent upstream pull requests and docs for the files involved), nobody has reported it, and it gives the maintainers new information. If any check fails, record the finding in the logs and do not post. The number of posts is never a reason to post.
- Offer a fix ("I can open a PR") only when the change can be verified end to end. Say plainly what remains unverified.
- Follow the upstream [CONTRIBUTING](https://github.com/nasa/fprime/blob/devel/CONTRIBUTING.md) and [AI policy](https://github.com/nasa/fprime/blob/devel/AI_POLICY.md) at the current `devel`. Open a pull request only after a maintainer accepts the issue. Until then, keep the fix on a local branch and push nothing.
- Keep a pull request to the change the issue describes. Do not add unrelated files, extra tests or documentation edits. Run the pinned `clang-format` on changed C++ files, and run the affected tests on Linux and, where relevant, on the QNX target.
- Fill in the upstream pull request template: `Fixes #nnnn`, a few bullets on what changed, one or two sentences on why, and how it was tested. Do not restate the diff. Disclose AI use in the template and check the change against the upstream [AI development skills](https://github.com/nasa/fprime/tree/devel/.github/skills).
- Before the owner posts, walk them through every changed line so that they can answer review questions themselves. Reply to review comments promptly and politely, and apply requested changes in small follow-up commits.
- Issue bodies follow the upstream bug template: version, affected component, problem with source links pinned to a full commit SHA, environment, reproduction, expected behavior and an AI usage section. Report test counts, not timing values.

Cases:

- U3 (`Drv_Ip` OS guard) and U2 (Rust for Ref) reproduced but were intended designs, introduced in nasa/fprime#6122 and nasa/fprime#6212. Neither was posted.
- nasa/fprime#6437 (POSIX UART) has no fix offer, because baud timing and hardware flow control need a physical serial device.
- nasa/fprime#6438 grouped three test assumptions with one cause into one issue and offered a pull request. The three-file, test-only fix waits locally for acceptance.
- nasa/fprime#6212 was closed within minutes because the first files a maintainer read looked unnecessary. It was reopened and merged after the author replied calmly and trimmed it to the requested check.
