# Notch Island — Roadmap

แอป macOS ที่วาด Notch Island (Dynamic-Island-style) ลอยกลางขอบบนจอ
ดีไซน์อ้างอิง: **แบบ A** (เรียบสุด ไม่มี container ซ้อน) — 3 states

โครงโค้ดปัจจุบัน:
- `NotchIsland/NotchModel.swift` — state + ข้อมูลตัวอย่าง + ขนาด (notch-aware)
- `NotchIsland/NotchView.swift` — SwiftUI ทั้ง 3 states
- `NotchIsland/NotchController.swift` — NSPanel ลอย, จัดตำแหน่ง/ย่อขยาย, ตรวจ hover
- `NotchIsland/MyApp.swift` — entry + MenuBarExtra

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

---

## จุดปรับแต่งที่ใช้บ่อย
- `NotchModel.sideModule` — ระยะช่องข้าง notch ตอน collapsed (ปัจจุบัน 44pt)
- `NotchController.notchInset(for:)` — ระยะเว้นด้านบนตอน expanded (= ความสูง menu bar/notch)
- `NotchController.openZone / stayZone` — โซน hover เปิด/อยู่ค้าง
- `NotchController.activeScreen() / adopt(_:)` — เลือก/สลับจอที่ island ไปเกาะ (ตามเมาส์)
- `NotchController` spring/animation duration — `0.42s ease-out`

## ดีไซน์อ้างอิง
- Canvas (แบบ A): https://claude.ai/artifact/Gmv8EGmsD5WAkmTsYiSr2e
- ไฟล์ source ดีไซน์: `design/Main.dc.html`, `design/canvas.json`
