# 图标素材

`LibreTV-symbol-source.png`由内置image_gen生成，透明背景；保留为原始素材。`icon-preview.png`是应用在深色背景上的预览。`Tools/export-artwork.swift`只负责平台所需的尺寸导出、背景图层和资源目录，不改变原始符号设计。

生成提示词：为家庭影院tvOS应用LibreTV制作一个原创蓝青色玻璃质感标志：L形丝带与向右播放三角结合，正面居中、透明背景、无文字/边框/水印，5:3画布并留出tvOS视差安全边距，小尺寸清晰。

重新导出：在仓库根目录运行`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift -module-cache-path /private/tmp/libretv-artwork-module-cache Tools/export-artwork.swift`。
