#!/usr/bin/env bash
# 确保标签对应的正式 Release 存在（三个平台的工作流并行运行，谁先到谁创建，其余直接上传）。
# 用法：ensure-release.sh <tag>；说明取自仓库根目录 RELEASE_NOTES.md。
set -euo pipefail
tag="$1"
title="Lyrico Mod ${tag#v}"
title="${title%-mod}（Android / iOS / Windows）"
for i in 1 2 3; do
  if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then exit 0; fi
  gh release create "$tag" --repo "$GITHUB_REPOSITORY" --verify-tag --latest \
    --title "$title" --notes-file RELEASE_NOTES.md && exit 0 || true
  sleep $((i * 5))
done
gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null
