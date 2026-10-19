# 文库图标

图标使用已确认的奶白人物剪影：闭眼侧脸、单侧发辫与书签发饰，搭配炭灰底色。

`app-icon-source.png` 是选定的原图，保留完整尺寸和材质，不重绘人物。`design-source.json` 保存底色、源文件名、Android 自适应安全区尺寸与图案比例；人物使用原图 88% 的尺寸，四周增加留白。

更新原图后运行：

```sh
flutter test tools/generate_app_icons.dart
```

生成器同步 Android 自适应／主题图标、常规启动图标、iOS 各尺寸和 `app-icon.png`。常规图标直接缩放原图；自适应图标从原图提取同一人物，保留奶白材质并预留圆形裁切安全区。旧的 `app-icon.svg` 不再参与生成。
