# SpektraCam

**v0.2.3 · iPhone · iOS 26.0+**（fork 版将最低版本由上游的 iOS 27.2 降至 26.0）

此App是基于 Andrea Volpato 的 [spektrafilm][upstream] 原生移植的 iPhone 照片编辑器。
免费、开源，支持简体中文与英文。

This App is a free, open-source iPhone photo editor built on a native port of Andrea Volpato’s [spektrafilm][upstream]. Supports Simplified Chinese and English.

## 功能 / Features

从“照片”或“文件”导入，保留原始文件并且单独保存编辑。
有裁剪、胶片与印相模拟、调整、颗粒、光晕和柔光，以及 JPEG/PNG 导出功能。
界面目前仅支持 iPhone 竖屏。

Import from Photos or Files. Keep originals and save edits separately. 
Crop, simulate film and prints, adjust color and tone, add grain, halation and diffusion, then export JPEG or PNG. 
The interface currently supports iPhone in portrait only.

简单的RAW 相机：拍摄 DNG；Apple ProRAW 和镜头支持取决于设备。
也可以跳过spektrafilm管线，直接使用最多两个独立混合的 `.cube` 3D LUT。
适用于编码后的 sRGB 图像，目前不支持 Log/HDR 输入变换。

The simple RAW camera captures DNG; Apple ProRAW and lens support depend on the device. 
You can also choose to bypass the spektrafilm pipeline and use up to two `.cube` 3D LUT slots have separate Mix controls. 
Use LUTs for encoded sRGB images; Log/HDR input transforms are not supported.

## 局限 / Limitations

**SpektraCam  只是提供近似胶片模拟，并不能精确还原某款胶片或实际工艺，也无法匹配不同相机传感器带来的差异。** 
胶片与印相数据主要来自于厂商官方的技术资料和公开研究，由 spektrafilm项目 重建与建模，作者并没有自行扫描或测量实体胶片来建立这些模型。[数据来源][profile-data] · [模型说明][model-notes]

**SpektraCam provides an approximate film simulation, not a precise reproduction of a film stock or process; It also unable to match the discrepancies among camera sensors.** 
Film and print data come mainly from official manufacturer datasheets and published research, reconstructed and modelled by spektrafilm. Missing data are filled using model estimates and assumptions. The author did not built these profiles from its own film scans or physical measurements. [Data sources][profile-data] · [Model notes][model-notes]

厂商提供的曲线描述的是指定测试条件下的代表性的表现，不能保证每盒或每卷胶片的结果。各种因素，比如光源、曝光、冲洗方法和药液状态、印相、扫描、胶片批次和存放条件都会对结果造成差异。[厂商说明示例][kodak]

Published curves describe representative behavior under specified test conditions, not a guarantee for each box or roll. Lighting, exposure, development method and chemistry, printing, scanning, film batch and storage can all change the result. [Manufacturer example][kodak]

Spektrafilm输入是解码后的 RGB 图像，而不是场景的实测光谱。
同时，胶片模型没有针对每款相机传感器的实测光谱响应来单独标定；相机差异和 RAW 解码方式会很大程度影响结果。

Input is decoded RGB, not measured scene spectra. 
The film model has no separate calibration for each camera sensor’s measured spectral response. Camera and RAW-decoding differences can affect the result.

LUT 模式中的颗粒、光晕与柔光是 RGB 适配，不是完整的光谱乳剂模型。
目前导出仅支持 SDR、sRGB、8 位。全分辨率导出受设备内存限制，极端的柔光设置可能导致 App 退出。

Grain, halation and diffusion in LUT mode are RGB adaptations, not a complete spectral emulsion model. 
Export is currently SDR, sRGB, 8-bit only. Export at full resolution is limited by device memory; extreme diffusion settings can terminate the app.

## 构建 / Build

使用 Xcode 26 或更高版本打开 [SpektraCam.xcodeproj](SpektraCam.xcodeproj)，选择模拟器或 iPhone 后运行。
真机安装需要选择自己的开发团队。Python 3 用于本机测试；UI 测试需先在测试模拟器中加入两张不同照片。

Open [SpektraCam.xcodeproj](SpektraCam.xcodeproj) in Xcode 26 or later, select a Simulator or iPhone, and run. Select your development team for device installation. Python 3 runs the native checks; UI tests need two different photos in the test Simulator.

```sh
python3 Scripts/core-checks.py
python3 Scripts/build-and-run.py --ui-tests
```

## 隐私 / Privacy

无账户、广告、追踪或分析 SDK。照片、编辑与 LUT 保存在设备本地。可选定位会写入拍摄位置；Apple 地图服务可能接收照片坐标以查询地名。导出、分享、系统备份与 TestFlight 诊断遵循对应的系统设置与隐私条款。

No accounts, ads, tracking or analytics SDKs. Photos, edits and LUTs stay on the device. Optional location access adds capture coordinates; Apple MapKit may receive photo coordinates to resolve place names. Export, sharing, system backups and TestFlight diagnostics follow the relevant system settings and privacy terms.

## 许可与致谢 / License and credits

代码采用 [GPLv3](LICENSE)；spektrafilm 配置与 LUT 数据采用 [CC BY-SA 4.0](SPEKTRAFILM_LICENSE.txt)。保留 Andrea Volpato 的原始署名、许可及[第三方声明](ThirdPartyNotices.txt)。

Code: [GPLv3](LICENSE). spektrafilm profiles and LUT data: [CC BY-SA 4.0](SPEKTRAFILM_LICENSE.txt). Preserve Andrea Volpato’s attribution, the licenses and [third-party notices](ThirdPartyNotices.txt).

[upstream]: https://github.com/andreavolpato/spektrafilm/tree/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc
[profile-data]: https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/profiles/io.py
[model-notes]: https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/README.md#introduction
[kodak]: https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf
