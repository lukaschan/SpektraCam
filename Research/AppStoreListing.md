# App Store listing drafts — SpektraCam

Drafts for App Store Connect. Character counts are against Apple's limits (name 30, subtitle 30,
keywords 100, promotional text 170). No manufacturer names, no other platforms, no Apple product
names in name, subtitle or keywords.

## App information

| Field | Value |
| --- | --- |
| Name | SpektraCam (10) — fallback: SpektraCam Darkroom (18) |
| Bundle ID | `io.github.runzeni.spektracam` |
| SKU | `spektracam-ios` |
| Primary language | English (U.S.); add Simplified Chinese |
| Category | Photo & Video |
| Price | Free |
| Age rating | 4+ (no to every content question; no social features, no web access) |
| Content rights | Contains third-party content (spektrafilm profiles, CC BY-SA 4.0); rights held under that licence |
| Privacy policy URL | `https://github.com/runzeni/SpektraCam/blob/main/PRIVACY.md` |
| Support URL | `https://github.com/runzeni/SpektraCam/issues` |
| Marketing URL | `https://github.com/runzeni/SpektraCam` |
| Copyright | © 2026 Runze Ni |
| Export compliance | No encryption |
| Availability | All territories except China mainland until an ICP filing number exists |

## App Privacy answers

**Data Not Collected.** The developer receives nothing. Reasoning to keep on file: the only
network request is MapKit reverse geocoding, which sends a photo's coordinates to Apple's own
service to return a place name; it is not linked to identity, not retained by the app beyond the
place name, and not available to the developer. If you prefer the most conservative reading,
declare *Location → Precise Location → App Functionality, not linked, not tracking* instead.

## English (U.S.)

**Subtitle** (30): `Film & darkroom photo editor`

**Promotional text** (≤170):
Spectral film simulation, a darkroom with paper, easel and film edges, and a RAW camera. Free and open source — every feature included.

**Keywords** (≤100): `film,analog,darkroom,raw,dng,grain,halation,lut,negative,slide,print,emulation,editor,proraw`

**Description**

SpektraCam develops your photos the way film does: through a spectral model of the negative, the
enlarger and the paper, not a colour filter.

It is a native port of spektrafilm, the open-source film simulation by Andrea Volpato. Free, no
ads, no accounts, nothing locked.

DEVELOP
• Colour negative, slide and cinema stocks, printed onto photographic paper or cinema print film, or scanned directly
• Film exposure, print exposure, print contrast and colour balance, with metering modes
• Dye couplers, print chemistry and scanner controls for those who want every parameter

EFFECTS
• Grain built from the emulsion model, with a separate black-and-white mode
• Halation and scatter
• Camera and enlarger diffusion filters

DARKROOM
• Paper sizes, borders and an easel you can set by hand
• Film edges for 35 mm, 120 and cinema formats, with sprocket holes
• Dust, scratches, fog and light leaks, from clean lab scan to old camera
• A loupe on a light table for checking the result

CAMERA
• RAW capture as DNG, with Apple ProRAW where the device supports it
• Lens selection, macro, exposure compensation and a live histogram

ALSO
• Import from Photos or Files; originals are never changed
• Crop, straighten and flip, with cinema and medium-format aspect ratios
• Up to two .cube 3D LUTs with separate mix, as an alternative to the film pipeline
• Undo history, before/after compare, batch export to JPEG or PNG
• English and Simplified Chinese

GOOD TO KNOW
The simulation is an approximation built mainly from published manufacturer data. It does not
reproduce any specific roll, lab or camera sensor. Export is SDR sRGB, 8-bit. Stock names identify
the data each profile is modelled on; SpektraCam is not affiliated with or endorsed by any film or
paper manufacturer.

Source code and licences: github.com/runzeni/SpektraCam

**What's New (1.0.0)**
First release: spectral film and print simulation, Darkroom with paper, easel, film edges and
distress, RAW camera, 3D LUTs and batch export.

## 简体中文

**副标题**（30）：`胶片与暗房照片编辑`

**宣传文本**：
光谱级胶片模拟，带相纸、放大尺和片边的暗房，以及 RAW 相机。免费开源，全部功能均可使用。

**关键词**（≤100）：`胶片,胶卷,暗房,模拟,负片,反转片,颗粒,光晕,相纸,印相,调色,滤镜,RAW,LUT,复古`

**描述**

SpektraCam 按胶片成像的方式处理照片：经过负片、放大机和相纸的光谱模型，而不是套一层滤镜。

本 App 是 Andrea Volpato 的开源胶片模拟项目 spektrafilm 的原生移植。免费，无广告，无账户，没有任何付费功能。

冲洗
• 彩色负片、反转片和电影胶片，可印相到相纸或电影拷贝片，也可直接扫描
• 胶片曝光、印相曝光、印相反差与色彩平衡，支持多种测光方式
• 成色剂、印相显影和扫描参数全部开放，供需要精细控制的用户使用

效果
• 基于乳剂模型生成的颗粒，另有黑白颗粒模式
• 光晕与散射
• 相机柔光与放大机柔光

暗房
• 相纸尺寸、白边和可手动放置的放大尺
• 35 mm、120 和电影画幅的胶片边缘，带齿孔
• 灰尘、划痕、灰雾与漏光，从干净的冲扫店扫描到老相机
• 看片台上的放大镜，用于检查细节

相机
• 拍摄 DNG 格式的 RAW 照片；设备支持时可用 Apple ProRAW
• 镜头切换、微距、曝光补偿与实时直方图

其他
• 从“照片”或“文件”导入；原图不会被修改
• 裁切、校正和翻转，提供电影与中画幅宽高比
• 最多两个 .cube 3D LUT，各自独立混合，可替代胶片管线
• 撤销历史、前后对比，批量导出 JPEG 或 PNG
• 支持英文与简体中文

须知
模拟结果是主要依据厂商公开资料建立的近似，不能精确还原某一卷胶片、某家冲扫店或某款相机传感器。导出为 SDR、sRGB、8 位。胶片与相纸名称仅用于标明各模拟所依据的数据；SpektraCam 与任何胶片或相纸厂商无关联，也未获其认可。

源代码与许可协议：github.com/runzeni/SpektraCam

**新功能（1.0.0）**
首个版本：光谱级胶片与印相模拟，带相纸、放大尺、胶片边缘和做旧效果的暗房，RAW 相机，3D LUT 与批量导出。

## Screenshots

Capture on a device, portrait, without manufacturer names in captions. Suggested set of six:
Library → Develop panel with a stock chosen → Effects (grain/halation) → Darkroom with film edge →
Darkroom print on paper with loupe → Camera. Repeat in Simplified Chinese.

## App Review notes

```
1. SCREEN RECORDING
[link — record on a physical iPhone from launch: import a photo, Develop, Effects,
Darkroom, Export → Save to Photos (shows the add-only Photos prompt), then Camera
(shows the camera and location prompts) and one RAW capture]

2. PURPOSE
SpektraCam is a free, open-source photo editor and RAW camera. It simulates
photographic film, enlarger and paper with a spectral model (a native port of the
open-source spektrafilm project by Andrea Volpato). It is for photographers who want
a physically motivated film look with full control, at no cost.

3. ACCESS
No account, login or purchase. All features are available on first launch.
- Tap + to import from Photos, or the info button → From Files.
- Open a photo → Develop. Panels: Develop, Adjust, Effects, Crop; the Darkroom button
  opens paper, film edge and distress controls.
- The camera button opens RAW capture (needs a physical device; ProRAW and lens
  choices depend on the hardware).
- About → Legal has the privacy policy, support link and licences.
There are no feature flags, remote configuration or hidden features.

4. EXTERNAL SERVICES
None operated by the developer. The only network request is Apple MapKit reverse
geocoding, used to show a place name for photos that contain GPS coordinates.
No analytics, ads or third-party SDKs.

5. REGIONAL DIFFERENCES
The app behaves the same in every region. Languages: English and Simplified Chinese.

6. REGULATED INDUSTRY
Not applicable.

OTHER
- Source code: https://github.com/runzeni/SpektraCam (GPLv3). Bundled film profile
  data is from spektrafilm under CC BY-SA 4.0; licences are shown in About → Legal.
- Film and paper names identify the published datasheets each profile is modelled on.
  The app states it is not affiliated with or endorsed by those manufacturers.
- This app is unrelated to other apps with similar names on the store.
```
