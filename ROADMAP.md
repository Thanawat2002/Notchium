# Notch Island — Roadmap

แอป macOS ที่วาด Notch Island (Dynamic-Island-style) ลอยกลางขอบบนจอ
ดีไซน์อ้างอิง: **แบบ A** (เรียบสุด ไม่มี container ซ้อน) — 3 states

โครงโค้ดปัจจุบัน:
- `NotchIsland/NotchModel.swift` — state + ข้อมูลตัวอย่าง + ขนาด (notch-aware)
- `NotchIsland/NotchView.swift` — SwiftUI ทุก state (collapsed / side controls / now playing / notification / snap picker)
- `NotchIsland/NotchController.swift` — NSPanel ลอย, จัดตำแหน่ง/ย่อขยาย, ตรวจ hover, ตามจอ
- `NotchIsland/NowPlayingProvider.swift` · `SystemAudio.swift` · `HotKey.swift` · `Motion.swift`
- `NotchIsland/WindowSnap.swift` — ตรวจจับลากหน้าต่าง + snap layouts (AX)
- `NotchIsland/SnapPreview.swift` — overlay กรอบ preview โซนเป้าหมาย
- `NotchIsland/MyApp.swift` — entry + MenuBarExtra
- `scripts/dev-run.sh` — build + เซ็น self-signed + relaunch (สิทธิ์ AX อยู่ข้าม build)

---

## ✅ Phase 0 — Prototype (เสร็จแล้ว)
- UI แบบ A ครบ 3 states (Collapsed / Now Playing / Notification)
- Hover ขยาย/ย่อ พร้อม hysteresis ไม่กระพริบ (ตรวจตำแหน่งเมาส์เทียบโซนคงที่บนจอ)
- Notch-aware: กลืนกับ notch จริง, artwork/bars ขนาบข้าง notch, expanded หลบใต้ notch
- MenuBarExtra สลับสถานะ + Keep Expanded
- ข้อมูลเป็น sample (เพลง/แจ้งเตือนตามภาพดีไซน์)

## ✅ Phase 1 — Interaction & polish (เสร็จแล้ว)
- ✅ ปุ่ม prev/next + chip + action มี hover ring/highlight + press (scale/dim) — `IconButton` / `Chip` / `ActionButton` + `PressableStyle`
- ✅ Notification "เด้ง" เข้ามา (scale + slide จากบน, spring) แล้ว **หดเองอัตโนมัติ ~4s** — `NotchModel.presentNotification()` + `alertActive`
- ✅ คลิกที่ notch เพื่อ pin/unpin — `.onTapGesture` บนตัว notch
- ✅ รองรับ Reduce Motion (ปิด bounce/scale, ย่อขยายแบบ instant) ทั้ง SwiftUI และ window resize
- ✅ จูน timing: window ease-out custom + content spring (response 0.42, damping 0.72)
- ⏳ Esc เพื่อย่อ — เลื่อนไปก่อน (ต้องขอสิทธิ์ Input Monitoring สำหรับ global key monitor)
  ใช้คลิก notch เพื่อ unpin แทนได้

## ✅ Phase 2 — Now Playing จริง 🎵 (เสร็จ — แนวทางเปลี่ยน)
- ⚠️ `MediaRemote` (now-playing ทั้งระบบ) ถูก Apple ล็อกตั้งแต่ macOS 15.4+ แล้ว — **ใช้ไม่ได้บน macOS 26** เลยไม่ใช้
- ✅ แทนด้วยการคุยกับแอปเพลงโดยตรง — Music.app + Spotify (`NowPlayingProvider.swift`)
  - อ่าน เพลง/ศิลปิน/อัลบั้ม/สถานะเล่น จาก **distributed notifications** (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) — ไม่ต้องขอสิทธิ์
  - อ่านตำแหน่ง (progress) + สั่ง play/pause/next/previous ผ่าน **AppleScript** — ขอสิทธิ์ Automation ครั้งแรก (มี `NSAppleEventsUsageDescription`)
  - progress + equalizer อัปเดตตามจริง, poll ตำแหน่งทุก 1s ระหว่างเล่น
  - ถ้าไม่มีเพลงเล่น → แสดง empty state
- ⏳ Artwork จริง — ยังเป็น placeholder (glyph โน้ต) ดึงภาพปกจาก Music/Spotify เป็นงานต่อ

## Phase 3 — Notification จริง 🔔
- แสดงแจ้งเตือนจริง + ปุ่ม actions ทำงาน (เปิด / ปิด / เตือนอีกครั้ง)
- คิวหลายอันเรียงกัน, auto-dismiss, กันสแปม
- ⚠️ การอ่าน notification ของระบบมีข้อจำกัด/ต้องขอสิทธิ์
  อาจเริ่มจากรับผ่าน API ของแอปเราเองก่อน

## ✅ Phase 4 — Multi-display (เสร็จ — แบบ A "ตามจอ active")
- ✅ island เดียว ตามจอที่เมาส์อยู่ realtime (เช็คในลูป hover 30Hz) — `NotchController.activeScreen()` / `adopt(_:)`
  - ย้ายจอแบบ **snap ทันที** ไม่สไลด์ข้ามจอ, คำนวณ notch geometry ของจอใหม่ทุกครั้ง
  - **ไม่ย้ายจอตอนขยายอยู่** (กันโดนดึงหนีมือตอนจะกดปุ่ม) — re-home เฉพาะตอนหุบ; pin ไว้ = อยู่กับที่
- ✅ จอไม่มี notch → โหมด **fake notch** (notchWidth 0 → pill วาดรูปเอง 200×32)
- ✅ `topInset` เป็น `@Published` → content หลบ menu bar/notch ของจอใหม่ถูกต้อง
- ✅ เสียบ/ถอด/จัดเรียงจอ → ปรับตามทันที (`didChangeScreenParametersNotification`) ไม่ต้องรีสตาร์ท
- ⏳ full-screen / Stage Manager / สลับ Space — ยังไม่ได้ทดสอบเจาะจง (collectionBehavior รองรับ all-spaces + fullScreenAuxiliary อยู่แล้ว)

## Phase 5 — Settings & lifecycle
- หน้า Preferences: เลือกจอ, ขนาด/ระยะ, เปิดปิดฟีเจอร์
- Launch at Login, hotkey เปิด/ย่อ
- บันทึกค่าที่ตั้งไว้ (UserDefaults)

## Phase 6 — Distribution 📦
- App icon + branding, code sign + notarize
- Sandbox / entitlements, อัปเดตอัตโนมัติ (ถ้าปล่อยนอก App Store)

## Phase 7 — เพิ่มเติม (optional)
- **แบบ B** (การ์ดย่อยจาง ๆ) เป็นธีมสลับได้
- Widget เสริม: ตัวจับเวลา, แบตเตอรี่, AirDrop, ไฟล์ที่ลากมาวาง

## ✅ Phase 8 — Snap Layouts 🪟 (เสร็จ — v1)
ลากหน้าต่างขึ้นไปหา notch → เกาะขยายเป็นแผงเลือก layout แล้วปล่อยเพื่อจัดหน้าต่าง (ดีไซน์แบบ A, 5 tile)
- ✅ ตรวจจับการลากหน้าต่างด้วย global mouse + Accessibility (AX) — `WindowSnapController`
  - ขอสิทธิ์ AX ครั้งเดียว (เมนู "Enable Window Snapping…"), เริ่ม watch เมื่อ trusted
  - กรอง scroll/select ออกด้วยการเช็คหน้าต่างขยับจริง + fallback ดูการเลื่อนเคอร์เซอร์
  - **รองรับ Electron** (Spotify/Claude ที่วาด title bar เอง) ผ่าน fallback `kAXFocusedWindow` ของแอปหน้าสุด
- ✅ 3 phase: off → **armed** (ใกล้ notch) → **picker** (ถึง notch, แผงเลื่อนลง)
- ✅ **เลือกโซนย่อย** ในแต่ละ tile: ครึ่งซ้ายขวา / 70-30 / สามคอลัมน์ / ซ้าย+ซ้อน / สี่ช่อง — ชี้บล็อกไหน snap โซนนั้น (`LayoutKind.regions`, `PickerMetrics` ชุดเดียวใช้ทั้งวาด+hit-test)
- ✅ **preview overlay** โปร่งแสงบนโซนเป้าหมายจริง (`SnapPreviewController`) — retarget ทันที ไม่กระพริบ
- ✅ snap จริงผ่าน AX (`kAXPosition`/`kAXSize`), เคารพ menu bar/Dock (`visibleFrame`)
- ⏳ ยังเป็น v1: โซนอิง `visibleFrame` ของจอที่เมาส์อยู่ (ยังไม่รองรับ snap ข้ามจอ), gap/ระยะขอบยังไม่ปรับได้, ยังไม่จำ layout

## Phase 9 — Drop Shelf (ที่พักไฟล์ชั่วคราว) 📎
ลากไฟล์/รูปเข้า notch → เกาะเก็บไว้ชั่วคราว → ลากออกไปวางที่ chat / โฟลเดอร์ / แอปอื่น
(แนวเดียวกับ Dropover / Yoink / NotchNook shelf)
- **รับ drop เข้า** — panel เป็น drag destination (`NSDraggingDestination` / SwiftUI `.onDrop`), รับ `NSItemProvider` (ไฟล์/รูป/URL/ข้อความ)
  - hover ลากไฟล์เข้าใกล้ notch → เกาะขยายเป็นถาดโชว์ thumbnail (ต่อยอดจาก presentation/ snap phase pattern)
  - เก็บได้หลายชิ้น เรียงเป็นแถว, ลบทีละชิ้น / เคลียร์ทั้งหมด
- **ลากออก** — เป็น drag source (`NSFilePromiseProvider` / เขียนไฟล์ชั่วคราวแล้วให้ file URL) เพื่อลากไปวางแอปอื่นได้
  - ไฟล์ที่ลากเข้าจากที่อื่น: อ้าง URL เดิม หรือ copy ลง temp (`FileManager` / `NSTemporaryDirectory`)
  - รูปจาก clipboard/ลากจากเว็บ: เขียนเป็นไฟล์ชั่วคราวก่อนให้ลากออก
- **จัดการอายุไฟล์** — temp items เคลียร์เมื่อปิดแอป หรือตั้งเวลา, กันเต็มดิสก์
- ⚠️ ข้อควรระวัง: sandbox ปิดอยู่แล้ว (เข้าถึงไฟล์ได้), แต่ต้องจัดการ security-scoped ถ้าเปิด sandbox ภายหลัง; ลากออกจาก non-activating panel ต้องทดสอบว่า drag session เริ่มได้

---

## จุดปรับแต่งที่ใช้บ่อย
- `NotchModel.sideModule` — ระยะช่องข้าง notch ตอน collapsed (ปัจจุบัน 44pt)
- `NotchController.notchInset(for:)` — ระยะเว้นด้านบนตอน expanded (= ความสูง menu bar/notch)
- `NotchController.openZone / stayZone` — โซน hover เปิด/อยู่ค้าง
- `NotchController.activeScreen() / adopt(_:)` — เลือก/สลับจอที่ island ไปเกาะ (ตามเมาส์)
- `NotchController` spring/animation duration — `0.42s ease-out`
- `WindowSnapController.armThreshold / pickerThreshold / pickerHalfWidth` — เกณฑ์ arm/เปิด picker ตอนลาก
- `SnapZones.frame(_:on:)` — โซนเป้าหมายต่อ tile/region (แก้ layout ที่นี่)
- `PickerMetrics` — ขนาด/ระยะ tile (ต้องตรงกันทั้ง view วาดและ monitor hit-test)

## ดีไซน์อ้างอิง
- Canvas (แบบ A): https://claude.ai/artifact/Gmv8EGmsD5WAkmTsYiSr2e
- ไฟล์ source ดีไซน์: `design/Main.dc.html`, `design/canvas.json`
