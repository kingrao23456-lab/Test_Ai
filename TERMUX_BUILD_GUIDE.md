# Zoya AI Assistant — Termux + GitHub se APK Build Guide

Ye guide tumhare Android device pe Termux se poora build karne ke liye hai.

## Kya bana hai (is scaffold me)

- `android/` — poora native Capacitor Android project (Kotlin)
  - `bridge/` — `ZoyaBridgePlugin.kt` (JS <-> Android bridge, PRD ke saare bridge functions)
  - `accessibility/` — `ZoyaAccessibilityService.kt`, `NodeFinder.kt`, `GestureExecutor.kt` (screen read, tap/swipe/type via official Accessibility API)
  - `capture/` — `ScreenCaptureService.kt` (MediaProjection)
  - `ocr/` — `OCRManager.kt` (ML Kit on-device OCR)
  - `camera/` — `CameraController.kt` (CameraX)
  - `settings/` — `SystemSettingsController.kt` (Wi-Fi/Bluetooth/brightness/volume settings)
  - `workflow/` — `WorkflowEngine.kt` (IF/WHILE/REPEAT/VERIFY workflow interpreter)
  - `scheduler/` — `TaskScheduler.kt` (WorkManager based scheduling)
  - `storage/` — `LocalStore.kt` (JSON file persistence)
  - `ui/` — `PermissionSetupActivity.kt`, `ConfirmActionActivity.kt` (sensitive-action confirmation)
- `src/lib/androidBridge.ts` — web app se native ko call karne ka typed wrapper

**Jaan-bujh kar chhoda gaya (agla phase):**
- Visual UI detection (computer-vision fallback) — sirf ek interface point hai, model training/integration alag kaam hai
- Shizuku/privileged integration — disabled by default, security-sensitive, alag se discuss karke banayenge
- App icons (mipmap) — Android Studio ka "Image Asset" wizard use karke apna icon generate karo

## Step-by-step Termux setup

### 1. Termux me packages install karo
```bash
pkg update && pkg upgrade -y
pkg install -y git nodejs-lts openjdk-17 gradle
```

### 2. Storage permission do
```bash
termux-setup-storage
```

### 3. Repo clone karo (apna GitHub repo)
```bash
git clone https://github.com/<tumhara-username>/<repo-name>.git
cd <repo-name>
```
Agar abhi GitHub pe nahi hai, to pehle ye poora `zoya-ai-assistant/` folder apne GitHub repo me push karo (GitHub Desktop/web upload ya `git init && git add . && git commit && git push` se), phir Termux me clone karo.

### 4. Dependencies install karo
```bash
npm install
```

### 5. Gemini API key set karo
`.env.example` ko `.env.local` me copy karke apni `GEMINI_API_KEY` daalo:
```bash
cp .env.example .env.local
nano .env.local
```

### 6. Web app build karo aur Capacitor sync karo
```bash
npm run build
npx cap sync android
```
Ye `dist/` folder ko `android/app/src/main/assets/public` me copy karega aur Capacitor ki native libraries (`capacitor-android`, plugins) ko `android/` project me link karega — jinhe humne `settings.gradle` me already reference kiya hua hai.

### 7. APK build karo
```bash
cd android
chmod +x gradlew
./gradlew assembleDebug
```
Build hone ke baad APK yahan milega:
```
android/app/build/outputs/apk/debug/app-debug.apk
```

### 8. Install karo
```bash
# same device pe:
pkg install -y android-tools   # agar termux-adb nahi hai
# ya seedha file manager se APK open karke install karo
```

## Common Termux issues

- **Gradle out of memory**: `android/gradle.properties` me `org.gradle.jvmargs=-Xmx2048m` already set hai; agar phone kam RAM ka hai, isse `-Xmx1024m` kar do.
- **`./gradlew: Permission denied`**: `chmod +x gradlew` chalao.
- **`SDK location not found`**: Termux me Android SDK nahi hota — agar sirf command-line build chahiye to `pkg install android-sdk` wale community repos use karne padte hain (thoda tricky), warna behtar hai ki `android/` folder ko Android Studio (laptop/PC) me khol kar build karo — zyada reliable hai.
- Agar Termux-only build chahte ho (bina Android Studio), bolo — main us specific setup (Termux + command-line-only Android SDK) ka alag guide bana dunga, kyunki wo Gradle/SDK licensing ke extra steps maangta hai.

## Agla step (Phase 2 automation build)

Ye scaffold compile-ready architecture hai lekin kuch jagah extension points hain (comments me `// extension point` dhoondo):
1. `captureScreen()` ka result `ScreenCaptureService` se activity result wire karna baaki hai (MainActivity me `onActivityResult` add karna hoga)
2. `performOCR()` ko capture ke frame se connect karna
3. App ke apne icons/splash screen

Jab ye build ho jaye aur chalu ho, agle session me hum in extension points ko complete karenge aur real device pe test karenge.
