# TODO / Roadmap

This file tracks confirmed unfinished work, not promised release dates.<br>
本文件只记录已经确认但尚未完成的工作，不代表发布日期承诺。

## Next UX Pass / 下一轮体验优化

- [ ] Replace the misleading “生成失败” state when the original is still usable. Use plain-language outcomes:
  - `已是较优结果`：没有找到更小且可靠的结果。
  - `还能继续压缩，建议检查`：存在更小结果，但清晰度需要用户判断。
  - `无法处理这张图片`：仅用于原图或快照本身不可用的真正失败。
- [ ] Make the result-panel Check button open the first item marked `建议检查` when nothing is selected.
- [ ] Show a compact `建议检查` badge beside the filename in the inspector and preserve previous/next navigation.
- [ ] Let eligible `无需压缩` items enter the inspector and try advanced quality levels without losing the original or last valid result.
- [ ] Add regression coverage for externally optimized JPEGs, partial candidate failures, and review-state navigation.

## Release Quality / 发布质量

- [ ] Complete hands-on validation for multi-display positioning, drag-out conflicts, ZIP, Trash/Undo, and caller integration.
- [ ] Measure launch and compression latency against the MVP performance targets.
- [ ] Recheck GPL corresponding-source materials and every bundled dependency notice for the exact release build.
