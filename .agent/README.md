# Coucou ZirconX Agent Workspace Index

This folder contains configuration, agent knowledge bases, architectural plans, and custom procedures for the Coucou project maintained by **ZirconX**.

---

## Documentation Index

| File | Purpose |
| :--- | :--- |
| **[`SYSTEM.md`](file:///C:/Users/ZirconX/coucou/.agent/SYSTEM.md)** | สถาปัตยกรรมระบบ โครงสร้างโปรเจกต์ และการทำงานของโมดูลต่างๆ |
| **[`rules/RULES.md`](file:///C:/Users/ZirconX/coucou/.agent/rules/RULES.md)** | กฎและมาตรฐานการพัฒนา (Identity, Code Integrity, i18n, Git) |
| **[`AGENTS.md`](file:///C:/Users/ZirconX/coucou/.agent/AGENTS.md)** | คำแนะนำการทำงานของ AI Coding Agents และคำสั่งการคอมไพล์ |
| **[`CHANGELOG.md`](file:///C:/Users/ZirconX/coucou/.agent/CHANGELOG.md)** | บันทึกประวัติการพัฒนาและฟีเจอร์ที่เพิ่มขึ้นในโปรเจกต์ ZirconX |

---

## Quick Reference Commands

```powershell
# ตรวจสอบ TypeScript compilation
cd windows
npx tsc --noEmit

# คอมไพล์ Hook Relay
cd windows\hook
cargo build --release

# สร้างตัวติดตั้ง MSI
cd windows
npx tauri build --bundles msi

# ซิงค์โค้ดและอัปเดตอัตโนมัติ
.\sync_and_update.bat
```
