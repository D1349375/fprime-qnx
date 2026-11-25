# QNX codelab drafts

This folder stages codelabs for [qnx/codelabs](https://github.com/qnx/codelabs) so they can be reviewed here first. Each codelab is one folder, `<id>/`, holding `<id>.md` and its images, in the layout that `qnx/codelabs` expects under `markdown/<id>/`.

| Codelab | Status |
| --- | --- |
| [Run the NASA F Prime Ref Deployment on QNX 8.0 with QEMU](fprime-ref-on-qnx/fprime-ref-on-qnx.md) | Draft. Screenshots, the pinned revision and the `published` date wait for the 12/07 freeze. Search the file for `TODO`. |

To submit a codelab, copy its folder to `markdown/<id>/` in a fork of `qnx/codelabs` and open a pull request that changes nothing outside that folder. Follow the [contribution codelab](https://qnx.github.io/codelabs/codelab-to-create-codelab/#0) and the metadata standard in the `qnx/codelabs` readme. To preview it, build claat from [qnx/tools](https://github.com/qnx/tools) and run `claat export -f html -o docs ./markdown/<id>/<id>.md` in the fork.
