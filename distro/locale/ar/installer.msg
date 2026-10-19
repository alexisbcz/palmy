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

msgid "Palmframe erases the disk you choose and creates a 512 MiB EFI system partition, a small BIOS boot partition so that older computers can start it too, and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "يمسح Palmframe القرص الذي تختاره وينشئ قسم نظام EFI بحجم 512 ميبيبايت، وقسم إقلاع BIOS صغيرًا لتتمكن الحواسيب الأقدم من تشغيله أيضًا، ونظام ملفات جذر ext4 على المساحة المتبقية. مشاركة القرص مع نظام آخر غير مدعومة."

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

# --- the keyboard page: a layout with no Latin letters -----------------------
msgid "This layout cannot type the Latin letters a user name needs, so English (US) comes with it: Alt+Shift switches between the two."
msgstr "لا يكتب هذا التخطيط الحروف اللاتينية التي يحتاجها اسم المستخدم، لذا يُضاف إليه تخطيط الإنجليزية (الولايات المتحدة): يبدّل Alt+Shift بينهما."

# --- the swap file (disk page, summary) -----------------------------------------
msgid "Create a swap file of %s"
msgstr "إنشاء ملف تبديل بحجم %s"

msgid "Room on the disk for memory that is not in use, so that a full memory slows the computer down instead of closing programs."
msgstr "مساحة على القرص للذاكرة غير المستخدمة، حتى يتباطأ الحاسوب عند امتلاء الذاكرة بدلًا من إغلاق البرامج."

msgid "Swap"
msgstr "التبديل"

msgid "A swap file of %s"
msgstr "ملف تبديل بحجم %s"

msgid "None"
msgstr "لا شيء"

# --- install_core's messages: validate() problems and progress details --------
# The msgids are MESSAGE_FORMAT in distro/installer/core/message.odin.
msgid "The user name is empty."
msgstr "اسم المستخدم فارغ."

msgid "The user name has more than 32 characters."
msgstr "يتجاوز اسم المستخدم 32 حرفًا."

msgid "The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'."
msgstr "يجب أن يبدأ اسم المستخدم %q بحرف لاتيني صغير أو '_' وألا يحتوي إلا على a-z و0-9 و'-' و'_'."

msgid "The user name %q is used by the system."
msgstr "اسم المستخدم %q يستخدمه النظام."

msgid "The full name may not contain ':' or line breaks, and has at most 128 characters."
msgstr "لا يجوز أن يحتوي الاسم الكامل على ':' أو فواصل أسطر، ولا يتجاوز 128 حرفًا."

msgid "The password is empty."
msgstr "كلمة المرور فارغة."

msgid "The password may not contain line breaks."
msgstr "لا يجوز أن تحتوي كلمة المرور على فواصل أسطر."

msgid "The root password may not contain line breaks."
msgstr "لا يجوز أن تحتوي كلمة مرور root على فواصل أسطر."

msgid "The host name is empty."
msgstr "اسم الحاسوب فارغ."

msgid "The host name is longer than 253 characters."
msgstr "يتجاوز اسم الحاسوب 253 حرفًا."

msgid "The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'."
msgstr "اسم الحاسوب %q غير صالح: يتكون كل جزء من 1 إلى 63 حرفًا ولا يبدأ أو ينتهي بـ '-'."

msgid "The host name %q may contain only letters, digits and '-'."
msgstr "لا يجوز أن يحتوي اسم الحاسوب %q إلا على حروف لاتينية وأرقام و'-'."

msgid "The language %q is not a locale name like fr_FR."
msgstr "اللغة %q ليست اسم إعدادات محلية مثل fr_FR."

msgid "The keyboard layout %q is not a valid name."
msgstr "تخطيط لوحة المفاتيح %q ليس اسمًا صالحًا."

msgid "The keyboard layout %s has no variant %q."
msgstr "لا يحتوي تخطيط لوحة المفاتيح %s على البديل %q."

msgid "There is no keyboard layout %q."
msgstr "لا يوجد تخطيط لوحة مفاتيح باسم %q."

msgid "The time zone %q is not a zone name like Europe/Paris."
msgstr "المنطقة الزمنية %q ليست اسم منطقة مثل Europe/Paris."

msgid "There is no time zone %q."
msgstr "لا توجد منطقة زمنية باسم %q."

msgid "The repository %q is neither an http:// URL nor an absolute path."
msgstr "المستودع %q ليس عنوان http:// ولا مسارًا مطلقًا."

msgid "%q is not a package name."
msgstr "%q ليس اسم حزمة."

msgid "The swap size %q is not a size like 2G or 512M."
msgstr "حجم التبديل %q ليس حجمًا مثل 2G أو 512M."

msgid "A swap file of %s leaves too little room on %s."
msgstr "ملف تبديل بحجم %s يترك مساحة قليلة جدًا على %s."

msgid "No disk is chosen."
msgstr "لم يُختر أي قرص."

msgid "%s is a device; a disk image must be a plain file."
msgstr "%s جهاز؛ يجب أن تكون صورة القرص ملفًا عاديًا."

msgid "The disk image %s is not a plain file."
msgstr "صورة القرص %s ليست ملفًا عاديًا."

msgid "The disk image %s holds %s; at least 4 GiB is needed."
msgstr "سعة صورة القرص %s هي %s؛ يلزم 4 جيبيبايت على الأقل."

msgid "%s holds the running system; choose another disk."
msgstr "يحمل %s النظام قيد التشغيل؛ اختر قرصًا آخر."

msgid "%s is read-only."
msgstr "%s للقراءة فقط."

msgid "%s holds %s; at least 4 GiB is needed."
msgstr "سعة %s هي %s؛ يلزم 4 جيبيبايت على الأقل."

msgid "%s has a mounted file system; unmount it first."
msgstr "على %s نظام ملفات مُركَّب؛ افصله أولًا."

msgid "There is no disk %s."
msgstr "لا يوجد قرص %s."

msgid "Partitioning"
msgstr "جارٍ التقسيم"

msgid "Formatting"
msgstr "جارٍ التهيئة"

msgid "Unmounting"
msgstr "جارٍ الفصل"

msgid "Writing the partition table"
msgstr "جارٍ كتابة جدول الأقسام"

msgid "Waiting for the kernel to see the new partitions"
msgstr "في انتظار أن ترى النواة الأقسام الجديدة"

msgid "Formatting the EFI system partition"
msgstr "جارٍ تهيئة قسم نظام EFI"

msgid "Formatting the root partition"
msgstr "جارٍ تهيئة قسم الجذر"

msgid "Installing %s (%s of %s)"
msgstr "جارٍ تثبيت %s (%s من %s)"

msgid "Setting the host name"
msgstr "جارٍ ضبط اسم الحاسوب"

msgid "Creating the user account"
msgstr "جارٍ إنشاء حساب المستخدم"

msgid "Setting language, keyboard and time zone"
msgstr "جارٍ ضبط اللغة ولوحة المفاتيح والمنطقة الزمنية"

msgid "Creating a %s swap file"
msgstr "جارٍ إنشاء ملف تبديل بحجم %s"

msgid "Writing the file system table"
msgstr "جارٍ كتابة جدول أنظمة الملفات"

msgid "Copying the boot loader"
msgstr "جارٍ نسخ محمِّل الإقلاع"

msgid "Copying the kernel"
msgstr "جارٍ نسخ النواة"

msgid "Making the disk start on BIOS computers"
msgstr "جارٍ تجهيز القرص للإقلاع على حواسيب BIOS"

msgid "Adding the UEFI boot entry"
msgstr "جارٍ إضافة مُدخَل إقلاع UEFI"

msgid "UEFI boot entry not written; the disk still boots through the fallback path"
msgstr "لم يُكتب مُدخَل إقلاع UEFI؛ سيُقلِع القرص مع ذلك عبر المسار الاحتياطي"
