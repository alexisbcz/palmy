# Palmy login screen (apps/greeter) — Arabic (Modern Standard).
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/ar/greeter.msg.
#
# Arabic has six plural forms: zero, one, two, few (3–10), many (11–99) and
# other (100, 101, 102...). The rule below is gettext's for Arabic, and kit's
# plural evaluator runs it as is, so each plural entry carries six msgstr[].
# Every form keeps its %d: Odin's fmt reports an unused argument in the text.
language  = ar
name      = العربية
english   = Arabic
direction = rtl
plural    = n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5

# --- the card ---------------------------------------------------------------
msgid "Sign in"
msgstr "تسجيل الدخول"

msgid "Authenticating"
msgstr "جارٍ التحقق"

msgid "Session ready"
msgstr "الجلسة جاهزة"

msgid "Signed in"
msgstr "تم تسجيل الدخول"

msgid "Password"
msgstr "كلمة المرور"

msgid "Answer"
msgstr "الإجابة"

msgid "Enter to sign in · Tab to move · Esc to clear"
msgstr "اضغط Enter للدخول · Tab للتنقل · Esc للمسح"

msgid "%d account"
msgid_plural "%d accounts"
msgstr[0] "%d حساب"
msgstr[1] "%d حساب"
msgstr[2] "%d حسابان"
msgstr[3] "%d حسابات"
msgstr[4] "%d حسابًا"
msgstr[5] "%d حساب"

msgid "%d session"
msgid_plural "%d sessions"
msgstr[0] "%d جلسة"
msgstr[1] "%d جلسة"
msgstr[2] "%d جلستان"
msgstr[3] "%d جلسات"
msgstr[4] "%d جلسة"
msgstr[5] "%d جلسة"

msgid "no local accounts"
msgstr "لا توجد حسابات محلية"

msgid "no sessions found"
msgstr "لم يُعثر على جلسات"

# --- errors and notices -----------------------------------------------------
msgid "Authentication failed"
msgstr "فشل التحقق"

msgid "Authentication failure"
msgstr "فشل التحقق"

msgid "The password was not accepted."
msgstr "لم تُقبل كلمة المرور."

msgid "greetd error"
msgstr "خطأ في greetd"

msgid "greetd accepted the session; it starts as soon as the greeter exits"
msgstr "قبل greetd الجلسة؛ ستبدأ فور إغلاق شاشة الدخول"

msgid "not connected to greetd at %s"
msgstr "غير متصل بـ greetd على %s"

msgid "there is no account to log in to"
msgstr "لا يوجد حساب لتسجيل الدخول إليه"

msgid "%s is a --demo-users placeholder, not a real account; it is never sent to greetd"
msgstr "%s مثال من --demo-users وليس حسابًا حقيقيًا؛ لا يُرسل أبدًا إلى greetd"

msgid "greetd sent an empty reply"
msgstr "أرسل greetd ردًا فارغًا"

msgid "greetd reported an error"
msgstr "أبلغ greetd عن خطأ"

msgid "no greetd on %s"
msgstr "لا يوجد greetd على %s"

msgid "MOCK greetd"
msgstr "greetd تجريبي"

msgid "greetd IPC · %s  (F2 hides this)"
msgstr "اتصال greetd · %s  (F2 للإخفاء)"

msgid "no socket"
msgstr "لا يوجد مقبس"

msgid "nothing sent yet"
msgstr "لم يُرسل شيء بعد"

# --- power ------------------------------------------------------------------
msgid "Suspend"
msgstr "سكون"

msgid "Restart"
msgstr "إعادة التشغيل"

msgid "Shut Down"
msgstr "إيقاف التشغيل"

msgid "Shutting down…"
msgstr "جارٍ إيقاف التشغيل…"

msgid "Restarting…"
msgstr "جارٍ إعادة التشغيل…"

msgid "power: would run `%s` (stub — nothing executed)"
msgstr "الطاقة: كان سيُنفَّذ `%s` (محاكاة — لم يُنفَّذ شيء)"

msgid "%s is not available on this machine"
msgstr "%s غير متاح على هذا الجهاز"

msgid "power: palm-login did not answer"
msgstr "الطاقة: لم يستجب palm-login"

msgid "power: %s"
msgstr "الطاقة: %s"

msgid "refused"
msgstr "مرفوض"

# --- the date ---------------------------------------------------------------
# Arguments: weekday, day of the month, month, year (Odin indices start at 0).
# Western digits; the month names are the Gregorian ones (يناير...) that
# Egyptian and Gulf usage, and most software, use.
msgid "%[0]s, %[1]d %[2]s %[3]d"
msgstr "%[0]s، %[1]d %[2]s %[3]d"

msgid "Sunday"
msgstr "الأحد"
msgid "Monday"
msgstr "الاثنين"
msgid "Tuesday"
msgstr "الثلاثاء"
msgid "Wednesday"
msgstr "الأربعاء"
msgid "Thursday"
msgstr "الخميس"
msgid "Friday"
msgstr "الجمعة"
msgid "Saturday"
msgstr "السبت"

msgid "January"
msgstr "يناير"
msgid "February"
msgstr "فبراير"
msgid "March"
msgstr "مارس"
msgid "April"
msgstr "أبريل"
msgid "May"
msgstr "مايو"
msgid "June"
msgstr "يونيو"
msgid "July"
msgstr "يوليو"
msgid "August"
msgstr "أغسطس"
msgid "September"
msgstr "سبتمبر"
msgid "October"
msgstr "أكتوبر"
msgid "November"
msgstr "نوفمبر"
msgid "December"
msgstr "ديسمبر"
