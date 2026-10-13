# Palmframe login screen (apps/greeter) — Japanese.
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/ja/greeter.msg.
#
# Japanese has no grammatical plural: `plural = 0` and one msgstr[0].
# It needs a CJK font on the target to render; see distro/locale/README.md.
language = ja
name     = 日本語
english  = Japanese
plural   = 0

# --- the card ---------------------------------------------------------------
msgid "Sign in"
msgstr "サインイン"

msgid "Authenticating"
msgstr "認証中"

msgid "Session ready"
msgstr "セッションの準備完了"

msgid "Signed in"
msgstr "サインインしました"

msgid "Password"
msgstr "パスワード"

msgid "Answer"
msgstr "回答"

msgid "Enter to sign in · Tab to move · Esc to clear"
msgstr "Enter でサインイン · Tab で移動 · Esc で消去"

msgid "%d account"
msgid_plural "%d accounts"
msgstr[0] "%d 個のアカウント"

msgid "%d session"
msgid_plural "%d sessions"
msgstr[0] "%d 個のセッション"

msgid "no local accounts"
msgstr "ローカルアカウントがありません"

msgid "no sessions found"
msgstr "セッションが見つかりません"

# --- errors and notices -----------------------------------------------------
msgid "Authentication failed"
msgstr "認証に失敗しました"

msgid "Authentication failure"
msgstr "認証に失敗しました"

msgid "The password was not accepted."
msgstr "パスワードが正しくありません。"

msgid "greetd error"
msgstr "greetd のエラー"

msgid "greetd accepted the session; it starts as soon as the greeter exits"
msgstr "greetd がセッションを受け付けました。ログイン画面が閉じるとすぐに始まります"

msgid "not connected to greetd at %s"
msgstr "%s の greetd に接続されていません"

msgid "there is no account to log in to"
msgstr "ログインできるアカウントがありません"

msgid "%s is a --demo-users placeholder, not a real account; it is never sent to greetd"
msgstr "%s は --demo-users の見本で、実在のアカウントではありません。greetd には送信されません"

msgid "greetd sent an empty reply"
msgstr "greetd から空の応答が届きました"

msgid "greetd reported an error"
msgstr "greetd がエラーを報告しました"

msgid "no greetd on %s"
msgstr "%s に greetd がありません"

msgid "MOCK greetd"
msgstr "模擬 greetd"

msgid "greetd IPC · %s  (F2 hides this)"
msgstr "greetd IPC · %s  (F2 で非表示)"

msgid "no socket"
msgstr "ソケットなし"

msgid "nothing sent yet"
msgstr "まだ何も送信していません"

# --- power ------------------------------------------------------------------
msgid "Suspend"
msgstr "スリープ"

msgid "Restart"
msgstr "再起動"

msgid "Shut Down"
msgstr "シャットダウン"

msgid "Shutting down…"
msgstr "シャットダウンしています…"

msgid "Restarting…"
msgstr "再起動しています…"

msgid "power: would run `%s` (stub — nothing executed)"
msgstr "電源: `%s` を実行するところです（スタブ — 何も実行していません）"

msgid "%s is not available on this machine"
msgstr "このマシンでは%sを使用できません"

msgid "power: palm-login did not answer"
msgstr "電源: palm-login が応答しませんでした"

msgid "power: %s"
msgstr "電源: %s"

msgid "refused"
msgstr "拒否されました"

# --- the date ---------------------------------------------------------------
# Arguments: weekday, day of the month, month, year (Odin indices start at 0).
# 2026年10月13日（火曜日）
msgid "%[0]s, %[1]d %[2]s %[3]d"
msgstr "%[3]d年%[2]s%[1]d日（%[0]s）"

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
