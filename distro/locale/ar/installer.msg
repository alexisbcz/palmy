# Palmframe installer (apps/installer) — Arabic (Modern Standard). The installer has no plural strings, but the rule is
# gettext's for Arabic so a later plural entry needs only its six msgstr[].
# Device paths, sizes and Palmframe stay in Latin script; palmy's bidi orders them.
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/ar/installer.msg.
#
# Every msgid in apps/installer must be here; `installer --selftest` checks
# that, and that % verbs and {placeholders} survive translation.
language  = ar
name      = العربية
english   = Arabic
direction = rtl
plural    = n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5

# --- the frame: rail, heading, buttons -----------------------------------------
msgid "Installer"
msgstr "المثبِّت"

msgid "Language"
msgstr "اللغة"

msgid "Keyboard"
msgstr "لوحة المفاتيح"

msgid "Time zone"
msgstr "المنطقة الزمنية"

msgid "Disk"
msgstr "القرص"

msgid "Account"
msgstr "الحساب"

msgid "Summary"
msgstr "الملخص"

msgid "Install"
msgstr "تثبيت"

msgid "Done"
msgstr "تم"

msgid "Demo"
msgstr "عرض تجريبي"

msgid "Nothing on this computer will be changed."
msgstr "لن يُغيَّر أي شيء على هذا الحاسوب."

msgid "Move"
msgstr "تنقّل"

msgid "Next"
msgstr "التالي"

msgid "Back"
msgstr "رجوع"

msgid "Step %d of %d"
msgstr "الخطوة %d من %d"

# --- page headings -------------------------------------------------------------
msgid "Welcome to Palmframe"
msgstr "مرحبًا بك في Palmframe"

msgid "Choose the language for the installer and for the new system."
msgstr "اختر لغة المثبِّت والنظام الجديد."

msgid "Keyboard layout"
msgstr "تخطيط لوحة المفاتيح"

msgid "Choose your keyboard layout. It takes effect at once, so you can try it below."
msgstr "اختر تخطيط لوحة المفاتيح. يُطبَّق فورًا، فيمكنك تجربته في الأسفل."

msgid "Choose the city nearest to you. The clock shows the time there."
msgstr "اختر أقرب مدينة إليك. تعرض الساعة الوقت فيها."

msgid "Installation disk"
msgstr "قرص التثبيت"

msgid "Choose the disk to install Palmframe on."
msgstr "اختر القرص الذي سيُثبَّت عليه Palmframe."

msgid "Your account"
msgstr "حسابك"

msgid "This account can administer the computer."
msgstr "يمكن لهذا الحساب إدارة الحاسوب."

msgid "Ready to install"
msgstr "جاهز للتثبيت"

msgid "Check your choices. Nothing has been changed yet."
msgstr "راجع اختياراتك. لم يُغيَّر أي شيء بعد."

msgid "Installing Palmframe"
msgstr "جارٍ تثبيت Palmframe"

msgid "This takes a few minutes. Every step is in the log."
msgstr "يستغرق ذلك بضع دقائق. كل خطوة مسجَّلة في السجل."

# --- 1. language ---------------------------------------------------------------
msgid "English"
msgstr "الإنجليزية"

msgid "French"
msgstr "الفرنسية"

msgid "German"
msgstr "الألمانية"

msgid "Spanish"
msgstr "الإسبانية"

msgid "Arabic"
msgstr "العربية"

msgid "Japanese"
msgstr "اليابانية"

msgid "Not available: no font for this script is installed"
msgstr "غير متاحة: لا يوجد خط مثبَّت لهذه الكتابة"

msgid "This language cannot be shown: no font for its script is installed"
msgstr "لا يمكن عرض هذه اللغة: لا يوجد خط مثبَّت لكتابتها"

# --- 2. keyboard ---------------------------------------------------------------
msgid "Layout"
msgstr "التخطيط"

msgid "Search layouts"
msgstr "ابحث في التخطيطات"

msgid "No layout matches your search."
msgstr "لا يوجد تخطيط يطابق بحثك."

msgid "Variant"
msgstr "الصيغة"

msgid "Default"
msgstr "الافتراضية"

msgid "Try your keyboard"
msgstr "جرّب لوحة المفاتيح"

msgid "Type here to test the layout"
msgstr "اكتب هنا لتجربة التخطيط"

msgid "Active: %s"
msgstr "النشط: %s"

msgid "No keyboard layouts were found"
msgstr "لم يُعثر على أي تخطيط للوحة المفاتيح"

# --- 3. time zone — the date line is a template: keep the {names}, move them freely ---
msgid "{weekday}, {day} {month} {year}"
msgstr "{weekday}، {day} {month} {year}"

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

msgid "%s · no time zone data on this system"
msgstr "%s · لا توجد بيانات للمناطق الزمنية على هذا النظام"

msgid "Search for a city, a region or a country"
msgstr "ابحث عن مدينة أو منطقة أو بلد"

msgid "No time zone matches your search."
msgstr "لا توجد منطقة زمنية تطابق بحثك."

msgid "No time zones were found"
msgstr "لم يُعثر على أي منطقة زمنية"

# --- 4. disk — sizes are binary units (GiB = 2^30 bytes) -----------------------
msgid "%.1f TiB"
msgstr "%.1f TiB"

msgid "%.1f GiB"
msgstr "%.1f GiB"

msgid "%d MiB"
msgstr "%d MiB"

msgid "The whole disk will be used"
msgstr "سيُستخدم القرص بأكمله"

msgid "Palmframe erases the disk you choose and creates two partitions: a 512 MiB EFI system partition and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "يمحو Palmframe القرص الذي تختاره وينشئ عليه قسمين: قسم نظام EFI بحجم 512 MiB ونظام ملفات جذر ext4 على المساحة الباقية. لا تُدعَم مشاركة القرص مع نظام آخر."

msgid "No disks were found. Attach a disk and restart the installer."
msgstr "لم يُعثر على أي قرص. صِل قرصًا ثم أعد تشغيل المثبِّت."

msgid "No disks were found"
msgstr "لم يُعثر على أي قرص"

msgid "Choose a disk"
msgstr "اختر قرصًا"

msgid "Removable"
msgstr "قابل للإزالة"

msgid "Has partitions"
msgstr "يحتوي على أقسام"

msgid "Its partitions and everything on them will be erased."
msgstr "ستُمحى أقسامه وكل ما عليها."

msgid "Unknown model"
msgstr "طراز غير معروف"

msgid "The live system is running from this disk"
msgstr "النظام الحي يعمل من هذا القرص"

msgid "This disk is read-only"
msgstr "هذا القرص للقراءة فقط"

msgid "Too small: Palmframe needs at least 4 GiB"
msgstr "صغير جدًا: يحتاج Palmframe إلى 4 GiB على الأقل"

# --- 4. disk — the erase confirmation ------------------------------------------
msgid "Erase %s?"
msgstr "أتريد محو %s؟"

msgid "%s, %s"
msgstr "%s، %s"

msgid "Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."
msgstr "سيُحذف كل ما على هذا القرص: كل قسم وكل ملف وأي نظام تشغيل آخر عليه. لا يمكن التراجع عن ذلك."

msgid "Cancel"
msgstr "إلغاء"

msgid "Erase %s"
msgstr "محو %s"

# --- 5. account ----------------------------------------------------------------
msgid "Full name"
msgstr "الاسم الكامل"

msgid "Ada Lovelace"
msgstr "فاطمة الفهري"

msgid "Optional. Shown on the login screen."
msgstr "اختياري. يظهر على شاشة تسجيل الدخول."

msgid "User name"
msgstr "اسم المستخدم"

msgid "ada"
msgstr "fatima"

msgid "Lowercase letters and digits; used to log in."
msgstr "حروف لاتينية صغيرة وأرقام؛ يُستخدم لتسجيل الدخول."

msgid "Computer name"
msgstr "اسم الحاسوب"

msgid "How this computer appears on a network."
msgstr "الاسم الذي يظهر به هذا الحاسوب على الشبكة."

msgid "Password"
msgstr "كلمة المرور"

msgid "Confirm password"
msgstr "تأكيد كلمة المرور"

msgid "Weak password"
msgstr "كلمة مرور ضعيفة"

msgid "Fair password"
msgstr "كلمة مرور متوسطة"

msgid "Strong password"
msgstr "كلمة مرور قوية"

msgid "Use the same password for the administrator (root)"
msgstr "استخدام كلمة المرور نفسها للمدير (root)"

msgid "Administrator password"
msgstr "كلمة مرور المدير"

msgid "Confirm administrator password"
msgstr "تأكيد كلمة مرور المدير"

msgid "Some fields need attention"
msgstr "بعض الحقول تحتاج إلى تصحيح"

# --- 5. account — what is wrong with a field -----------------------------------
msgid "A name cannot contain a colon or a comma"
msgstr "لا يمكن أن يحتوي الاسم على نقطتين رأسيتين أو فاصلة"

msgid "Choose a user name"
msgstr "اختر اسم مستخدم"

msgid "A user name has at most 32 characters"
msgstr "لا يتجاوز اسم المستخدم 32 حرفًا"

msgid "A user name starts with a lowercase letter"
msgstr "يبدأ اسم المستخدم بحرف لاتيني صغير"

msgid "Use only lowercase letters, digits, hyphens and underscores"
msgstr "استخدم الحروف اللاتينية الصغيرة والأرقام والشرطات والشرطات السفلية فقط"

msgid "This name is already used by the system"
msgstr "هذا الاسم يستخدمه النظام بالفعل"

msgid "Choose a name for this computer"
msgstr "اختر اسمًا لهذا الحاسوب"

msgid "A computer name has at most 63 characters"
msgstr "لا يتجاوز اسم الحاسوب 63 حرفًا"

msgid "Use letters, digits and hyphens, without a hyphen at either end"
msgstr "استخدم حروفًا لاتينية وأرقامًا وشرطات، دون شرطة في البداية أو النهاية"

msgid "Choose a password"
msgstr "اختر كلمة مرور"

msgid "The passwords do not match"
msgstr "كلمتا المرور غير متطابقتين"

msgid "Choose a password for the administrator"
msgstr "اختر كلمة مرور للمدير"

# --- 6. summary ----------------------------------------------------------------
msgid "%s will be erased"
msgstr "سيُمحى %s"

msgid "%s, %s. Everything on it will be lost when you press Install."
msgstr "%s، %s. سيُفقد كل ما عليه عند الضغط على «تثبيت»."

msgid "GPT: 512 MiB EFI system partition, ext4 root on the rest"
msgstr "GPT: قسم نظام EFI بحجم 512 MiB، وجذر ext4 على المساحة الباقية"

msgid "The administrator uses the same password"
msgstr "يستخدم المدير كلمة المرور نفسها"

msgid "The administrator has its own password"
msgstr "للمدير كلمة مرور خاصة به"

msgid "Change"
msgstr "تغيير"

msgid "The installer refused this plan"
msgstr "رفض المثبِّت هذه الإعدادات"

msgid "The disk has not been confirmed"
msgstr "لم يُؤكَّد القرص"

# --- 7. install ----------------------------------------------------------------
msgid "Partitioning the disk"
msgstr "جارٍ تقسيم القرص"

msgid "Creating file systems"
msgstr "جارٍ إنشاء أنظمة الملفات"

msgid "Mounting"
msgstr "جارٍ ربط الأقسام"

msgid "Installing packages"
msgstr "جارٍ تثبيت الحزم"

msgid "Configuring the system"
msgstr "جارٍ إعداد النظام"

msgid "Installing the boot loader"
msgstr "جارٍ تثبيت محمِّل الإقلاع"

msgid "Finishing"
msgstr "جارٍ الإنهاء"

msgid "The installation failed"
msgstr "فشل التثبيت"

msgid "Show details"
msgstr "إظهار التفاصيل"

msgid "Hide details"
msgstr "إخفاء التفاصيل"

msgid "Back to summary"
msgstr "العودة إلى الملخص"

msgid "Restart"
msgstr "إعادة التشغيل"

# --- 8. done -------------------------------------------------------------------
msgid "Palmframe is installed"
msgstr "تم تثبيت Palmframe"

msgid "Remove the installation medium, then restart the computer to start your new system."
msgstr "أزل وسيط التثبيت، ثم أعد تشغيل الحاسوب لبدء استخدام نظامك الجديد."

msgid "Restart now"
msgstr "أعد التشغيل الآن"
