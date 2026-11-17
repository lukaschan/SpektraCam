# App Store listing drafts — SpektraCam

Drafts for App Store Connect. Character counts are against Apple's limits (name 30, subtitle 30,
keywords 100, promotional text 170). No manufacturer names, no other platforms, no Apple product
names in name, subtitle or keywords.

Updated for the Formulae-based **1.0 (11)** candidate on 17 November 2026. Publish the Formula
link page and finish device verification before using these drafts for submission.

## App information

| Field | Value |
| --- | --- |
| Name | SpektraCam (10) — fallback: SpektraCam Darkroom (18) |
| Bundle ID | `io.github.runzeni.spektracam` |
| SKU | `spektracam-ios` |
| Primary language | English (U.S.); add Simplified Chinese |
| Category | Photo & Video |
| Price | Free |
| Age rating | Expected 4+; complete Apple's current questionnaire from the actual features |
| Content rights | Contains third-party content (spektrafilm profiles, CC BY-SA 4.0); rights held under that licence |
| Privacy policy URL | `https://github.com/runzeni/SpektraCam/blob/main/PRIVACY.md` |
| Support URL | `https://github.com/runzeni/SpektraCam/issues` |
| Marketing URL | `https://github.com/runzeni/SpektraCam` |
| Copyright | © 2026 Runze Ni |
| Export compliance | No non-exempt encryption (`ITSAppUsesNonExemptEncryption = NO`) |
| Availability | All territories except China mainland until an ICP filing number exists |

## App Privacy answers

**Proposed: Data Not Collected**, subject to the developer confirming the final answers. Photos,
edits, formulae and LUTs are stored locally; there are no developer analytics or advertising SDKs.
MapKit receives coordinates for a real-time place-name request. Opening the external Formula
page makes an ordinary request to GitHub Pages, with formula data kept in the fragment and decoded
locally. No formula or photograph is uploaded to a developer service. Confirm the final answers
against [Apple's definition of collection](https://developer.apple.com/app-store/app-privacy-details/),
which concerns off-device access beyond servicing a request in real time.

## English (U.S.)

**Subtitle** (27): `Film & darkroom photo editor`

**Promotional text** (≤170):
Spectral film simulation, a RAW camera, a darkroom and reusable Formulae. Share a look as a file, link or Formula Card. Free and open source.

**Keywords** (≤100): `film,analog,darkroom,raw,dng,grain,halation,lut,negative,slide,print,editor,formula,qr`

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

FORMULAE
• Save reusable looks with separate Look, Exposure and Darkroom parts
• Copy and paste between photos, or apply a formula to a selection, with undo
• Share .rnformula files, self-contained links and Formula Cards with a QR code
• Import from a file, a card image or a pasted link, with a preview before adding
• Missing LUTs are identified; LUT files are included in a shared file only when you choose

ALSO
• Import from Photos or Files; originals are never changed
• Crop, straighten and flip, with cinema and medium-format aspect ratios
• Up to two .cube 3D LUTs with separate mix, as an alternative to the film pipeline
• Undo history, before/after compare, batch export to JPEG or PNG
• Export an original captured RAW file without reprocessing it
• English and Simplified Chinese

GOOD TO KNOW
The simulation is an approximation built mainly from published manufacturer data. It does not
reproduce any specific roll, lab or camera sensor. Export is SDR sRGB, 8-bit. Stock names identify
the data each profile is modelled on; SpektraCam is not affiliated with or endorsed by any film or
paper manufacturer.

Source code and licences: github.com/runzeni/SpektraCam

**What's New (1.0)**
First release: spectral film and print simulation, Darkroom, RAW camera, 3D LUTs, batch export,
and saved Formulae with file, link and QR Formula Card sharing.

## 简体中文

**副标题**（30）：`胶片与暗房照片编辑`

**宣传文本**：
光谱级胶片模拟、RAW 相机、暗房与可重复使用的配方。通过文件、链接或带二维码的配方卡共享效果。免费开源。

**关键词**（≤100）：`胶片,胶卷,暗房,模拟,负片,反转片,颗粒,光晕,相纸,印相,调色,滤镜,配方,配方卡,RAW,LUT,复古`

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
• 相纸尺寸、白边和可手动放置的尺板
• 35 mm、120 和电影画幅的胶片边缘，带齿孔
• 灰尘、划痕、灰雾与漏光，从干净的冲扫店扫描到老相机
• 看片台上的放大镜，用于检查细节

相机
• 拍摄 DNG 格式的 RAW 照片；设备支持时可用 Apple ProRAW
• 镜头切换、微距、曝光补偿与实时直方图

配方
• 保存可重复使用的效果，分别选择个性化、曝光与暗房部分
• 在照片间复制粘贴，或将配方应用到所选照片，支持撤销
• 通过 .rnformula 文件、包含配方本身的链接或带二维码的配方卡共享
• 从文件、配方卡图片或粘贴的链接导入，添加前先预览
• 明确提示缺少的 LUT；只有你选择附带时，共享文件才会包含 LUT 文件

其他
• 从“照片”或“文件”导入；原图不会被修改
• 裁切、校正和翻转，提供电影与中画幅宽高比
• 最多两个 .cube 3D LUT，各自独立混合，可替代胶片管线
• 撤销历史、前后对比，批量导出 JPEG 或 PNG
• 直接导出拍摄的原始 RAW 文件，无需重新处理
• 支持英文与简体中文

须知
模拟结果是主要依据厂商公开资料建立的近似，不能精确还原某一卷胶片、某家冲扫店或某款相机传感器。导出为 SDR、sRGB、8 位。胶片与相纸名称仅用于标明各模拟所依据的数据；SpektraCam 与任何胶片或相纸厂商无关联，也未获其认可。

源代码与许可协议：github.com/runzeni/SpektraCam

**新功能（1.0）**
首个版本：光谱级胶片与印相模拟、暗房、RAW 相机、3D LUT、批量导出，以及支持文件、链接与二维码配方卡共享的配方。

## Screenshots

Supply current iPhone and 13-inch iPad screenshots using the sizes accepted by
[Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
Use actual app captures with images you may publish, without alpha channels. Suggested views:
Develop, Darkroom, Formulae manager, Formula Card, LUTs and Camera (real hardware).
The verification captures use synthetic charts and are not a finished marketing set.

## App Review notes

```
1. SCREEN RECORDING
A physical-device demonstration recording is to be supplied separately after the release
candidate device pass. The app's RAW camera requires supported hardware.

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
- Library → Formulae opens the Formulae/LUTs manager. Develop a photo, open its information
  panel and choose Save as Formula. Look, Exposure and Darkroom are selectable parts;
  crop and rotation are excluded. Apply a saved formula from a photo's information panel
  or to a selection through Apply Formula.
- A formula's page offers Share, Copy Link and Formula Card. A card may contain a chosen
  developed photo and a QR code. Manager → Import offers From Files, From Card Image and
  Paste Link. Every route shows an import preview before adding anything.
- Formula links carry settings after # and never carry LUT file contents. A formula requiring
  a missing LUT is not applied until the LUT is installed or explicitly replaced.
- HTTPS formula links open a static browser page with Open in SpektraCam and a file download.
  Open in SpektraCam uses the spektracam:// scheme; universal links are not enabled.
- About → Legal has the privacy policy, support link and licences.
There are no feature flags, remote configuration or hidden features.

4. EXTERNAL SERVICES
Apple MapKit reverse geocoding resolves coordinates into photo place names. An external
formula link opens a static GitHub Pages page and decodes the URL fragment locally; there is
no formula upload, account service or backend. No analytics, ads or third-party SDKs.

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
