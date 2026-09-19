---
name: Bug report
about: Report a defect in image_bytes_cache or image_bytes_cache_flutter
title: ""
labels: ""
assignees: ""
---

**Package**
Which package is affected?

- [ ] `image_bytes_cache` (pure Dart core)
- [ ] `image_bytes_cache_flutter` (paint adapters)

**Platform**
Where does it fail?

- [ ] VM (mobile / desktop / server)
- [ ] Web (Chrome / other)
- [ ] Both / unsure

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:

1. Source / setup is ...
2. Run the command or widget ...
3. See specific error or unexpected behavior

**Expected behavior**
A clear and concise description of what you expected to happen.

**Web-related?**
If this touches web blob storage, Cache API, OPFS, or `ImageBytesCache.open` on web: did you (or CI) run

`dart test -p chrome test/open/open_web_test.dart`

from `packages/image_bytes_cache`?

- [ ] Yes
- [ ] No / not applicable

**Additional context**
SDK / Flutter versions, logs, screenshots, or other context.
