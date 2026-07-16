# Build Verification Gate — Session State (لاستكمال العمل بين الجلسات)

> **الغرض:** هذا الملف يسجّل الحالة الحيّة لبوابة التحقق من البناء (Build
> Verification Gate) بحيث يمكن استئناف العمل من نفس النقطة في أي جلسة لاحقة
> دون فقدان أي سياق. اقرأه أولاً ثم `docs/project-context.md` §4.

_آخر تحديث: 2026-07-15 (الجلسة 2)._

> **ملاحظة دمج (Session Handoff):** الحقائق في هذا الملف تم توحيدها داخل
> `docs/project-context.md` §4 (نقطة 4) بتاريخ 2026-07-15. `project-context.md`
> هو المصدر الوحيد للحالة — هذا الملف سجل خام تفصيلي فقط، لا تعتمد عليه وحده
> إذا تعارض مع §4.

---

## 0. بيئة التنفيذ الفعلية (مهم جداً — قيود حقيقية)

الجلسة تعمل داخل sandbox من Genspark (Debian 13, x86_64). القيود المؤكدة:

| المورد | القيمة | الأثر |
|--------|--------|-------|
| RAM | **985 MiB فقط** (متاح ~610 MiB) | بطيء جداً؛ `flutter analyze` تجاوز مهلة 400s مرة |
| القرص | 27G (متاح ~19G) | كافٍ |
| Flutter | **مثبّت يدوياً: 3.44.0 / Dart 3.12.0** ✅ (يطابق `.fvmrc` و `pubspec.lock`) | يعمل |
| Android SDK | **غير موجود** ❌ | `flutter build apk` **سيفشل/يُحجب** |
| macOS/Xcode | **غير موجود** ❌ | `flutter build ios` **يُتخطّى** |
| Chrome | غير موجود | لا يمنع `build web --release` (فقط التشغيل التفاعلي) |

### كيفية إعداد البيئة في أي جلسة جديدة
Flutter منزَّل خارج المشروع في `/home/user/flutter` (ليس داخل الأرشيف).
إن لم يكن موجوداً (جلسة جديدة/sandbox جديد)، أعد تنزيله:
```bash
cd /home/user
curl -s -o flutter_sdk.tar.xz \
  "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.44.0-stable.tar.xz"
tar -xf flutter_sdk.tar.xz && rm flutter_sdk.tar.xz
git config --global --add safe.directory '*'
```
ثم في كل أمر:
```bash
export PATH="/home/user/flutter/bin:/home/user/flutter/bin/cache/dart-sdk/bin:/home/user/.pub-cache/bin:$PATH"
```
مسار المشروع الحالي في هذا الـ sandbox: `/home/user/nukhba_work/nukhba`
(الأرشيف الأصلي: `/home/user/uploaded_files/nukhba_snapshot_موحد.tar.gz`).

---

## 1. الخطوات الثماني (من §4) — لوحة التقدّم الحيّة

| # | الخطوة | الأمر | الحالة | ملاحظة |
|---|--------|-------|--------|--------|
| 1 | melos bootstrap / pub get | `dart pub get` (workspace root) | ✅ PASS | "Got dependencies!" بنفس إصدارات pubspec.lock |
| 2 | flutter pub get (mobile) | مغطّى بـ workspace resolution | ✅ PASS | resolution: workspace |
| 3 | build_runner (6× .g.dart) | — | ✅ مؤكد سابقاً | لا يُعاد ما لم يتغير المصدر |
| 4 | flutter analyze | `dart analyze --fatal-infos --fatal-warnings .` | 🔴 FAIL | 307 issues (168 errors/0 warn/119 info), exit 3 — الجلسة 2 |
| 5 | flutter test / dart test | — | ⬜ لم يبدأ | 8 مجلدات test |
| 6 | flutter build web --release | — | ⬜ لم يبدأ | متوقّع أن ينجح |
| 7 | flutter build apk --release | — | ⛔ محجوب | لا Android SDK — سيُسجَّل BLOCKED |
| 8 | flutter build ios | — | ⏭️ يُتخطّى | لا macOS |

**قاعدة صارمة (من §4):** عند أي فشل حقيقي → أصلح السبب الجذري في المصدر،
لا تُعطّل اختباراً، لا تُضعف `analysis_options.yaml`، لا تمسّ منطق الأعمال
المُصادق عليه. أعد تشغيل التسلسل بعد كل إصلاح.

---

## 2. سجل النتائج الحرفي (يُملأ تدريجياً)

### الخطوة 4 — flutter analyze
- الأمر الأساسي: `flutter analyze` → لم يكتمل (تجاوز 510s، ذاكرة مقيّدة) — قُتِل.
- الأمر البديل (المصادق عليه في §4): `dart analyze --fatal-infos --fatal-warnings .`
- الحالة: 🔴 **FAIL (الجلسة 2، 2026-07-15)** — اكتمل في ~90s.
- النتيجة الحرفية: **`307 issues found.` / exit code 3 — 168 errors, 0 warnings, 119 info.**
- الناتج الخام محفوظ في: `docs/reviews/analyze-raw-session2.txt` (312 سطر).
- التقرير الكامل: `docs/reviews/build-verification-report.md`.
- السبب الجذري: استيرادات ناقصة/خاطئة + انحراف بسيط في مساعدات الاختبار — لا منطق أعمال.
  الخطأ الإنتاجي الوحيد: استيراد ناقص في
  `apps/server/routes/groups/[id]/feed/index.dart`
  (`import 'package:application/application.dart';`). البقية في ملفات test.
- **البوابة ليست GREEN؛ الخطوات 5–8 لم تُشغَّل.**

### الخطوة 5 — الاختبارات
- _(لم تبدأ)_

### الخطوة 6 — build web
- _(لم تبدأ)_

---

## 3. الخطوة التالية عند الاستئناف

1. أعدّ البيئة (قسم 0 أعلاه).
2. تحقق من ناتج `flutter analyze` (الخطوة 4) — أصلح أي مشاكل في الكود الفعلي.
3. انتقل للخطوة 5 (الاختبارات) ثم 6 (build web).
4. سجّل كل ناتج هنا وفي `docs/reviews/build-verification-report.md`.
5. عند اكتمال كل شيء GREEN: حدّث بانر `project-context.md` و §4 و
   `flutter-app-review.md` كما هو مفصّل في §4 "Deliverable".
6. عبّئ `nukhba_snapshot_final.tar.gz` وارفعه لمستكشف الملفات.

**لا تُعِد فتح أي مرحلة من المراحل الـ12. لا تدّعِ GREEN قبل ناتج حرفي فعلي.**
