# Palmframe installer (apps/installer) — Japanese. Needs a CJK font on the live system to render; the installer lists
# 日本語 as unavailable when none is installed (distro/notes/installer-gui.md).
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/ja/installer.msg.
#
# Every msgid in apps/installer must be here; `installer --selftest` checks
# that, and that % verbs and {placeholders} survive translation.
language  = ja
name      = 日本語
english   = Japanese
plural    = 0

# --- the frame: rail, heading, buttons -----------------------------------------
msgid "Installer"
msgstr "インストーラー"

msgid "Language"
msgstr "言語"

msgid "Keyboard"
msgstr "キーボード"

msgid "Time zone"
msgstr "タイムゾーン"

msgid "Disk"
msgstr "ディスク"

msgid "Account"
msgstr "アカウント"

msgid "Summary"
msgstr "概要"

msgid "Install"
msgstr "インストール"

msgid "Done"
msgstr "完了"

msgid "Demo"
msgstr "デモ"

msgid "Nothing on this computer will be changed."
msgstr "このコンピューターは一切変更されません。"

msgid "Move"
msgstr "移動"

msgid "Next"
msgstr "次へ"

msgid "Back"
msgstr "戻る"

msgid "Step %d of %d"
msgstr "ステップ %d / %d"

# --- page headings -------------------------------------------------------------
msgid "Welcome to Palmframe"
msgstr "Palmframe へようこそ"

msgid "Choose the language for the installer and for the new system."
msgstr "インストーラーと新しいシステムの言語を選んでください。"

msgid "Keyboard layout"
msgstr "キーボード配列"

msgid "Choose your keyboard layout. It takes effect at once, so you can try it below."
msgstr "キーボード配列を選んでください。すぐに反映されるので、下で試せます。"

msgid "Choose the city nearest to you. The clock shows the time there."
msgstr "最寄りの都市を選んでください。時計にはその地域の時刻が表示されます。"

msgid "Installation disk"
msgstr "インストール先のディスク"

msgid "Choose the disk to install Palmframe on."
msgstr "Palmframe をインストールするディスクを選んでください。"

msgid "Your account"
msgstr "あなたのアカウント"

msgid "This account can administer the computer."
msgstr "このアカウントでコンピューターを管理できます。"

msgid "Ready to install"
msgstr "インストールの準備ができました"

msgid "Check your choices. Nothing has been changed yet."
msgstr "選んだ内容を確認してください。まだ何も変更されていません。"

msgid "Installing Palmframe"
msgstr "Palmframe をインストールしています"

msgid "This takes a few minutes. Every step is in the log."
msgstr "数分かかります。各ステップはログに記録されます。"

# --- 1. language ---------------------------------------------------------------
msgid "English"
msgstr "英語"

msgid "French"
msgstr "フランス語"

msgid "German"
msgstr "ドイツ語"

msgid "Spanish"
msgstr "スペイン語"

msgid "Arabic"
msgstr "アラビア語"

msgid "Japanese"
msgstr "日本語"

msgid "Not available: no font for this script is installed"
msgstr "利用できません: この文字のフォントがインストールされていません"

msgid "This language cannot be shown: no font for its script is installed"
msgstr "この言語は表示できません: 文字のフォントがインストールされていません"

# --- 2. keyboard ---------------------------------------------------------------
msgid "Layout"
msgstr "配列"

msgid "Search layouts"
msgstr "配列を検索"

msgid "No layout matches your search."
msgstr "検索に一致する配列はありません。"

msgid "Variant"
msgstr "バリエーション"

msgid "Default"
msgstr "標準"

msgid "Try your keyboard"
msgstr "キーボードを試す"

msgid "Type here to test the layout"
msgstr "ここに入力して配列を試せます"

msgid "Active: %s"
msgstr "使用中: %s"

msgid "No keyboard layouts were found"
msgstr "キーボード配列が見つかりません"

# --- 3. time zone — the date line is a template: keep the {names}, move them freely ---
msgid "{weekday}, {day} {month} {year}"
msgstr "{year}年{month}{day}日 {weekday}"

msgid "Sunday"
msgstr "日曜日"

msgid "Monday"
msgstr "月曜日"

msgid "Tuesday"
msgstr "火曜日"

msgid "Wednesday"
msgstr "水曜日"

msgid "Thursday"
msgstr "木曜日"

msgid "Friday"
msgstr "金曜日"

msgid "Saturday"
msgstr "土曜日"

msgid "January"
msgstr "1月"

msgid "February"
msgstr "2月"

msgid "March"
msgstr "3月"

msgid "April"
msgstr "4月"

msgid "May"
msgstr "5月"

msgid "June"
msgstr "6月"

msgid "July"
msgstr "7月"

msgid "August"
msgstr "8月"

msgid "September"
msgstr "9月"

msgid "October"
msgstr "10月"

msgid "November"
msgstr "11月"

msgid "December"
msgstr "12月"

msgid "%s · no time zone data on this system"
msgstr "%s · このシステムにはタイムゾーンのデータがありません"

msgid "Search for a city, a region or a country"
msgstr "都市、地域、国名で検索"

msgid "No time zone matches your search."
msgstr "検索に一致するタイムゾーンはありません。"

msgid "No time zones were found"
msgstr "タイムゾーンが見つかりません"

# --- 4. disk — sizes are binary units (GiB = 2^30 bytes) -----------------------
msgid "%.1f TiB"
msgstr "%.1f TiB"

msgid "%.1f GiB"
msgstr "%.1f GiB"

msgid "%d MiB"
msgstr "%d MiB"

msgid "The whole disk will be used"
msgstr "ディスク全体が使われます"

msgid "Palmframe erases the disk you choose and creates a 512 MiB EFI system partition, a small BIOS boot partition so that older computers can start it too, and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "Palmframe は選んだディスクを消去し、512 MiB の EFI システムパーティション、古いコンピューターでも起動できるようにする小さな BIOS ブートパーティション、残り全体の ext4 ルートファイルシステムを作成します。ほかのシステムとのディスクの共有には対応していません。"

msgid "No disks were found. Attach a disk and restart the installer."
msgstr "ディスクが見つかりません。ディスクを接続してから、インストーラーを再起動してください。"

msgid "No disks were found"
msgstr "ディスクが見つかりません"

msgid "Choose a disk"
msgstr "ディスクを選んでください"

msgid "Removable"
msgstr "リムーバブル"

msgid "Has partitions"
msgstr "パーティションあり"

msgid "Its partitions and everything on them will be erased."
msgstr "パーティションとその中身はすべて消去されます。"

msgid "Unknown model"
msgstr "不明なモデル"

msgid "The live system is running from this disk"
msgstr "ライブシステムがこのディスクから動作しています"

msgid "This disk is read-only"
msgstr "このディスクは読み取り専用です"

msgid "Too small: Palmframe needs at least 4 GiB"
msgstr "容量不足: Palmframe には 4 GiB 以上が必要です"

# --- 4. disk — the erase confirmation ------------------------------------------
msgid "Erase %s?"
msgstr "%s を消去しますか?"

msgid "%s, %s"
msgstr "%s、%s"

msgid "Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."
msgstr "このディスク上のすべてのパーティション、ファイル、ほかのオペレーティングシステムが削除されます。元に戻すことはできません。"

msgid "Cancel"
msgstr "キャンセル"

msgid "Erase %s"
msgstr "%s を消去"

# --- 5. account ----------------------------------------------------------------
msgid "Full name"
msgstr "氏名"

msgid "Ada Lovelace"
msgstr "山田 花子"

msgid "Optional. Shown on the login screen."
msgstr "任意。ログイン画面に表示されます。"

msgid "User name"
msgstr "ユーザー名"

msgid "ada"
msgstr "hanako"

msgid "Lowercase letters and digits; used to log in."
msgstr "英小文字と数字。ログインに使います。"

msgid "Computer name"
msgstr "コンピューター名"

msgid "How this computer appears on a network."
msgstr "ネットワーク上でのこのコンピューターの名前です。"

msgid "Password"
msgstr "パスワード"

msgid "Confirm password"
msgstr "パスワード(確認)"

msgid "Weak password"
msgstr "弱いパスワード"

msgid "Fair password"
msgstr "普通のパスワード"

msgid "Strong password"
msgstr "強いパスワード"

msgid "Use the same password for the administrator (root)"
msgstr "管理者 (root) にも同じパスワードを使う"

msgid "Administrator password"
msgstr "管理者のパスワード"

msgid "Confirm administrator password"
msgstr "管理者のパスワード(確認)"

msgid "Some fields need attention"
msgstr "入力内容を確認してください"

# --- 5. account — what is wrong with a field -----------------------------------
msgid "A name cannot contain a colon or a comma"
msgstr "名前にコロンやカンマは使えません"

msgid "Choose a user name"
msgstr "ユーザー名を入力してください"

msgid "A user name has at most 32 characters"
msgstr "ユーザー名は 32 文字以内です"

msgid "A user name starts with a lowercase letter"
msgstr "ユーザー名は英小文字で始めてください"

msgid "Use only lowercase letters, digits, hyphens and underscores"
msgstr "英小文字、数字、ハイフン、アンダースコアのみ使えます"

msgid "This name is already used by the system"
msgstr "この名前はシステムで使われています"

msgid "Choose a name for this computer"
msgstr "このコンピューターの名前を入力してください"

msgid "A computer name has at most 63 characters"
msgstr "コンピューター名は 63 文字以内です"

msgid "Use letters, digits and hyphens, without a hyphen at either end"
msgstr "英字、数字、ハイフンを使えます。先頭と末尾にハイフンは使えません"

msgid "Choose a password"
msgstr "パスワードを入力してください"

msgid "The passwords do not match"
msgstr "パスワードが一致しません"

msgid "Choose a password for the administrator"
msgstr "管理者のパスワードを入力してください"

# --- 6. summary ----------------------------------------------------------------
msgid "%s will be erased"
msgstr "%s は消去されます"

msgid "%s, %s. Everything on it will be lost when you press Install."
msgstr "%s、%s。「インストール」を押すと、このディスクの内容はすべて失われます。"

msgid "GPT: 512 MiB EFI system partition, ext4 root on the rest"
msgstr "GPT: 512 MiB の EFI システムパーティション、残りは ext4 のルート"

msgid "The administrator uses the same password"
msgstr "管理者も同じパスワードを使います"

msgid "The administrator has its own password"
msgstr "管理者は別のパスワードを使います"

msgid "Change"
msgstr "変更"

msgid "The installer refused this plan"
msgstr "インストーラーがこの設定を受け付けませんでした"

msgid "The disk has not been confirmed"
msgstr "ディスクが確認されていません"

# --- 7. install ----------------------------------------------------------------
msgid "Partitioning the disk"
msgstr "ディスクをパーティション分割しています"

msgid "Creating file systems"
msgstr "ファイルシステムを作成しています"

msgid "Mounting"
msgstr "マウントしています"

msgid "Installing packages"
msgstr "パッケージをインストールしています"

msgid "Configuring the system"
msgstr "システムを設定しています"

msgid "Installing the boot loader"
msgstr "ブートローダーをインストールしています"

msgid "Finishing"
msgstr "仕上げています"

msgid "The installation failed"
msgstr "インストールに失敗しました"

msgid "Show details"
msgstr "詳細を表示"

msgid "Hide details"
msgstr "詳細を隠す"

msgid "Back to summary"
msgstr "概要に戻る"

msgid "Restart"
msgstr "再起動"

# --- 8. done -------------------------------------------------------------------
msgid "Palmframe is installed"
msgstr "Palmframe をインストールしました"

msgid "Remove the installation medium, then restart the computer to start your new system."
msgstr "インストールメディアを取り外してから、コンピューターを再起動すると新しいシステムが始まります。"

msgid "Restart now"
msgstr "今すぐ再起動"

# --- the swap file (disk page, summary) -----------------------------------------
msgid "Create a swap file of %s"
msgstr "%s のスワップファイルを作成する"

msgid "Room on the disk for memory that is not in use, so that a full memory slows the computer down instead of closing programs."
msgstr "使われていないメモリーを置くためのディスク上の領域です。メモリーがいっぱいになっても、プログラムが終了される代わりに動作が遅くなるだけで済みます。"

msgid "Swap"
msgstr "スワップ"

msgid "A swap file of %s"
msgstr "%s のスワップファイル"

msgid "None"
msgstr "なし"

# --- install_core's messages: validate() problems and progress details --------
# The msgids are MESSAGE_FORMAT in distro/installer/core/message.odin.
msgid "The user name is empty."
msgstr "ユーザー名が空です。"

msgid "The user name has more than 32 characters."
msgstr "ユーザー名が 32 文字を超えています。"

msgid "The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'."
msgstr "ユーザー名 %q は英小文字か「_」で始め、a-z、0-9、「-」、「_」だけを使ってください。"

msgid "The user name %q is used by the system."
msgstr "ユーザー名 %q はシステムが使用しています。"

msgid "The full name may not contain ':' or line breaks, and has at most 128 characters."
msgstr "フルネームには「:」や改行を使えません。また 128 文字以内にしてください。"

msgid "The password is empty."
msgstr "パスワードが空です。"

msgid "The password may not contain line breaks."
msgstr "パスワードに改行は使えません。"

msgid "The root password may not contain line breaks."
msgstr "root のパスワードに改行は使えません。"

msgid "The host name is empty."
msgstr "コンピューター名が空です。"

msgid "The host name is longer than 253 characters."
msgstr "コンピューター名が 253 文字を超えています。"

msgid "The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'."
msgstr "コンピューター名 %q は無効です。各部分は 1〜63 文字で、「-」で始まったり終わったりしてはいけません。"

msgid "The host name %q may contain only letters, digits and '-'."
msgstr "コンピューター名 %q には英字、数字、「-」だけが使えます。"

msgid "The language %q is not a locale name like fr_FR."
msgstr "言語 %q は fr_FR のようなロケール名ではありません。"

msgid "The keyboard layout %q is not a valid name."
msgstr "キーボード配列 %q は有効な名前ではありません。"

msgid "The keyboard layout %s has no variant %q."
msgstr "キーボード配列 %s にはバリエーション %q がありません。"

msgid "There is no keyboard layout %q."
msgstr "キーボード配列 %q はありません。"

msgid "The time zone %q is not a zone name like Europe/Paris."
msgstr "タイムゾーン %q は Europe/Paris のようなゾーン名ではありません。"

msgid "There is no time zone %q."
msgstr "タイムゾーン %q はありません。"

msgid "The repository %q is neither an http:// URL nor an absolute path."
msgstr "リポジトリー %q は http:// の URL でも絶対パスでもありません。"

msgid "%q is not a package name."
msgstr "%q はパッケージ名ではありません。"

msgid "The swap size %q is not a size like 2G or 512M."
msgstr "スワップサイズ %q は 2G や 512M のようなサイズではありません。"

msgid "A swap file of %s leaves too little room on %s."
msgstr "%s のスワップファイルでは %s の空き容量が足りなくなります。"

msgid "No disk is chosen."
msgstr "ディスクが選ばれていません。"

msgid "%s is a device; a disk image must be a plain file."
msgstr "%s はデバイスです。ディスクイメージは通常のファイルでなければなりません。"

msgid "The disk image %s is not a plain file."
msgstr "ディスクイメージ %s は通常のファイルではありません。"

msgid "The disk image %s holds %s; at least 4 GiB is needed."
msgstr "ディスクイメージ %s の容量は %s です。4 GiB 以上が必要です。"

msgid "%s holds the running system; choose another disk."
msgstr "%s では現在のシステムが動いています。別のディスクを選んでください。"

msgid "%s is read-only."
msgstr "%s は読み取り専用です。"

msgid "%s holds %s; at least 4 GiB is needed."
msgstr "%s の容量は %s です。4 GiB 以上が必要です。"

msgid "%s has a mounted file system; unmount it first."
msgstr "%s にはマウントされたファイルシステムがあります。先にアンマウントしてください。"

msgid "There is no disk %s."
msgstr "ディスク %s はありません。"

msgid "Partitioning"
msgstr "パーティションを作成しています"

msgid "Formatting"
msgstr "フォーマットしています"

msgid "Unmounting"
msgstr "アンマウントしています"

msgid "Writing the partition table"
msgstr "パーティションテーブルを書き込んでいます"

msgid "Waiting for the kernel to see the new partitions"
msgstr "カーネルが新しいパーティションを認識するのを待っています"

msgid "Formatting the EFI system partition"
msgstr "EFI システムパーティションをフォーマットしています"

msgid "Formatting the root partition"
msgstr "ルートパーティションをフォーマットしています"

msgid "Installing %s (%s of %s)"
msgstr "%s をインストールしています（%s / %s）"

msgid "Setting the host name"
msgstr "コンピューター名を設定しています"

msgid "Creating the user account"
msgstr "ユーザーアカウントを作成しています"

msgid "Setting language, keyboard and time zone"
msgstr "言語、キーボード、タイムゾーンを設定しています"

msgid "Creating a %s swap file"
msgstr "%s のスワップファイルを作成しています"

msgid "Writing the file system table"
msgstr "ファイルシステムテーブルを書き込んでいます"

msgid "Copying the boot loader"
msgstr "ブートローダーをコピーしています"

msgid "Copying the kernel"
msgstr "カーネルをコピーしています"

msgid "Making the disk start on BIOS computers"
msgstr "BIOS のコンピューターでも起動できるようにしています"

msgid "Adding the UEFI boot entry"
msgstr "UEFI ブートエントリーを追加しています"

msgid "UEFI boot entry not written; the disk still boots through the fallback path"
msgstr "UEFI ブートエントリーを書き込めませんでしたが、ディスクは予備のパスから起動できます"
