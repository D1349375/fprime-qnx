# QNX Codelabs

Each folder is laid out for review in this repository and for later submission under `markdown/<id>/` in [qnx/codelabs](https://github.com/qnx/codelabs).

| Codelab | Exercise |
| --- | --- |
| [Run the NASA F Prime Ref Deployment on QNX 8.0 with QEMU](fprime-ref-on-qnx/fprime-ref-on-qnx.md) | Build upstream Ref for a QNX guest, send a NO-OP from GDS, and see both responses and rate group telemetry. |
| [Observe F Prime ADCS Fault Recovery on QNX 8.0](fprime-adcs-fault-recovery-on-qnx/fprime-adcs-fault-recovery-on-qnx.md) | Follow the stopped advisor, FDIR takeover, SLM replacement, and acceptance of a new advisor session in GDS. |

Both tutorials were last verified on 2026-11-27 at commit `752c5d4d7786767744440089a1e2224db7e9e145`, and the screenshots come from that run. The commit includes the GDS check repairs from the first rehearsal, the guest start and lease fixes and the GDS shutdown fix. [Rehearsal](../zh/實作迭代紀錄.md#i-92--rehearse-both-qnx-codelabs-2026-11-26) · [Refresh](../zh/實作迭代紀錄.md#i-99--refresh-both-qnx-codelabs-2026-11-27)

## Preview both drafts

Build `claat` from the [QNX fork](https://github.com/qnx/tools/tree/e385f1d0eb8697b2e5ea626c877553864a11deb0/claat), then run this from the project root. The temporary QNX Codelabs checkout supplies the shared JavaScript and stylesheets for the preview.

```bash
PREVIEW="$(mktemp -d)"
git clone --depth 1 https://github.com/qnx/codelabs.git "$PREVIEW/qnx-codelabs"
claat export -f html -o "$PREVIEW/qnx-codelabs/docs" \
    docs/codelab/fprime-ref-on-qnx/fprime-ref-on-qnx.md \
    docs/codelab/fprime-adcs-fault-recovery-on-qnx/fprime-adcs-fault-recovery-on-qnx.md
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$PREVIEW/qnx-codelabs/docs"
```

Open [Ref preview](http://localhost:8080/fprime-ref-on-qnx/) and [ADCS preview](http://localhost:8080/fprime-adcs-fault-recovery-on-qnx/).

## Freeze and submit

1. When the submission revision is frozen, check whether it changes any file the tutorials use: the GDS and guest helper scripts, `scripts/import-ref.sh`, `adoption/ref-qnx.patch`, `FprimeQnx`, `FprimeQnxReference` or the host setup guide. If none changed, the verified commit stays. Otherwise replace the SHA in both checkout commands and project links.
2. After a SHA change, rerun both tutorials at that revision, replace the screenshots and update the **Last verified** line with the SHA and run date. Recheck links, metadata, and both rendered previews.
3. The project owner submits one PR per tutorial. Each PR changes only its own `markdown/<id>/` directory in `qnx/codelabs`. Submit with `status: published` and set `published` to the date the PR opens, as the open contributions in that repository do. Merged external codelabs show their merge date, so a maintainer may change `published` at merge. A `draft` codelab stays off the landing page after merge. If the PR opens on a later date, update `published` first. The text and screenshots describe application behavior only, under [D95](../zh/決策與變更紀錄.md#d95--apply-the-organizer-reply-on-qnx-evaluations-2026-11-28). [Contribution guide](https://qnx.github.io/codelabs/codelab-to-create-codelab/#0) · [Metadata standard](https://github.com/qnx/codelabs/blob/eaddbfbcb271db18645fc760ee411c0293a30d6a/readme.md#metadata-standard)
