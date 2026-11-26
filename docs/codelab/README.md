# QNX Codelabs

Each folder is laid out for review in this repository and for later submission under `markdown/<id>/` in [qnx/codelabs](https://github.com/qnx/codelabs).

| Codelab | Exercise |
| --- | --- |
| [Run the NASA F Prime Ref Deployment on QNX 8.0 with QEMU](fprime-ref-on-qnx/fprime-ref-on-qnx.md) | Build upstream Ref for a QNX guest, send a NO-OP from GDS, and see both responses and rate group telemetry. |
| [Observe F Prime ADCS Fault Recovery on QNX 8.0](fprime-adcs-fault-recovery-on-qnx/fprime-adcs-fault-recovery-on-qnx.md) | Follow the stopped advisor, FDIR takeover, SLM replacement, and acceptance of a new advisor session in GDS. |

Both drafts use the pre-freeze rehearsal commit `37db15be76f60b5c5084032d9ec1325be0885439`. The screenshots document that rehearsal. The review branch includes the two GDS check fixes used in the reruns. [Implementation and verification](../zh/實作迭代紀錄.md#i-92--rehearse-both-qnx-codelabs-2026-11-26)

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

1. Replace the rehearsal SHA in both checkout commands and project links with the full `SUBMISSION_COMMIT` SHA when the submission revision is frozen.
2. Rerun both tutorials at that revision, apply any verified E11 setup corrections, replace the rehearsal screenshots and add a **Last verified** line with the final SHA and run date. Recheck links, metadata, and both rendered previews.
3. The project owner submits one PR per tutorial. Each PR changes only its own `markdown/<id>/` directory in `qnx/codelabs`. Keep `status: draft` during project review. Before publication, set `status: published` and set `published` to the first publication date. [Contribution guide](https://qnx.github.io/codelabs/codelab-to-create-codelab/#0)
