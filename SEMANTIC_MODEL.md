# Local semantic candidate ranking

Squirrel can optionally map an Octagram grammar database named
`wanxiang-lts-zh-hans.gram` from either:

- `~/Library/Rime/wanxiang-lts-zh-hans.gram`
- `~/Library/Application Support/Squirrel/Models/wanxiang-lts-zh-hans.gram`

The grammar score is fused with Rime's original rank and the local adaptive
preference score. Missing or invalid models fall back to adaptive ranking
without blocking input.

The compatible Wanxiang LTS Simplified Chinese model is published by
`amzxyz/RIME-LMDG` under CC BY 4.0:

https://github.com/amzxyz/RIME-LMDG

The memory-mapped database format and query encoding are compatible with the
GPL-3.0 `librime-octagram` implementation:

https://github.com/lotem/librime-octagram
