# Third-party notices

CineSlice includes or was built with the following open-source work.

## DBS-TIGER-DnR (voice split)

`PocketInstrument/Media/Tiger*.mlpackage` are Core ML conversions of the DBS-TIGER-DnR speech
model, made with `Tools/dbs_tiger/export.py`. The band splitting was rewritten with dense
operations so Core ML can run it; the weights are unchanged apart from 16-bit storage.

- Source: https://github.com/JusperLee/Dynamic-Band-Splitting (Tsinghua University)
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0

## HTDemucs (earlier versions only)

Earlier commits of this repository contain `PocketInstrument/Media/HTDemucs.mlpackage`, a Core ML
conversion of Meta's HTDemucs made with `Tools/demucs/export.py`. It was removed in f7f1267.

- Source: https://github.com/facebookresearch/demucs
- License: MIT License, Copyright (c) Meta Platforms, Inc. and affiliates.
