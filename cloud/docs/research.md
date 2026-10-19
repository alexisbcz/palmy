# What people hate and love in the suites we are up against

Research for the Palmy account, its identities and the apps on top of it.
The question is narrow: where Google Workspace, Microsoft 365, iCloud, Proton,
Zoho, Fastmail, HEY, Superhuman, Notion and Linear fail or delight people, in
the areas that a *one account, several identities* design touches. Collected
October 2026.

**How much to trust this.** Every link below either appeared in search results
or was opened. Most items were read through search summaries, not end to end;
the Microsoft Work Trend Index page was opened and checked. Items marked
**[vendor]** come from a company selling a fix for the problem it describes,
and **[weak]** marks a single anecdote or an SEO page. Forum evidence is mostly
Microsoft Tech Community, Microsoft Q&A, Apple Community, Google support
threads and Hacker News. Reddit did not surface in search, so its absence is a
gap in the method, not a finding.

---

## 1. Switching accounts is broken by design, not by bug

Both incumbents bolted several identities onto a model that assumed one.

**Google: the first account you signed into wins.** The "default" Google
account is whichever was signed in first in that browser. Changing it later
means signing out of all of them and back in, in order, on every device
([Business Insider, 2019](https://www.businessinsider.in/how-to-change-your-default-google-account/articleshow/69133266.cms);
[Anson Alex](https://ansonalex.com/tutorials/change-default-gmail-account-using-google-multiple-sign-in/)).

**Google URLs number your accounts by sign-in order.** `/u/1/` and
`?authuser=1` mean "the second account you happened to sign into", so a link
opens as whoever that is on the recipient's machine. There is a Chrome
extension whose only job is to add `?authuser=1` to Meet links
([Chrome Web Store](https://chromewebstore.google.com/detail/fjapamfgnflnfgfolgcjmmnfmmmkbphg)).
On Hacker News, someone signed in with a college account still gets told by
Docs that they "don't have permission"
([HN, 2010](https://news.ycombinator.com/item?id=3062023)).

**Access is checked against the active account only.** Drive asks the active
account, not all the ones you are signed into, so a correctly shared file
answers "you need access"
([Canvas community](https://community.canvaslms.com/t5/Canvas-Question-Forum/Student-unable-to-access-file-on-google-drive/m-p/613248)).
Someone built a "Google Account Auto Switcher" that retries the link as each
of your other accounts
([Notion page](https://coldbru.notion.site/Google-Account-Auto-Switcher-31e928163e0c8037a625c68612f4f970)).
When people write their own tools to cope, the pain is real.

**Microsoft: one address, two accounts.** The same email can belong to a
personal Microsoft account and to a work or school Entra account. That is
where "Pick an account" comes from, and the pair of errors "there's already an
account" and "that account doesn't exist" that are both true. The two cannot
be merged
([Office Watch, 2021](https://office-watch.com/2021/solving-theres-already-an-account-microsoft-login-problem/);
[GoDaddy help](https://www.godaddy.com/help/why-do-i-have-more-than-one-microsoft-account-41996)).
One university notes that its own IT cannot see who created the older personal
accounts on its domain
([University of Maine](https://tdx.maine.edu/TDClient/2624/Portal/KB/PrintArticle?ID=139059)).

**Teams shows only one tenant at a time.** A guest in another organisation
has to switch to it. While switched away, they appear offline at home and
miss its notifications. People run a second tenant in an incognito window
([Tech Community, 2019](https://techcommunity.microsoft.com/discussions/microsoftteams/enhancement-request---remove-the-switching-behavior-in-teams/1056786/replies/1057019);
[2021](https://techcommunity.microsoft.com/discussions/microsoftteams/fast-user-switching-between-orgs-tenant/2876533/replies/2877678)).

**The workaround everyone is told to use is the browser profile.** IT
departments tell people to use one Chrome profile per account, because a second
account inside one profile leaves "Drive, Gmail… confused about which account
goes with which app". Profiles are local to one machine
([Free Tech 4 Teachers](https://freetech4teach.teachermade.com/?p=13556);
[Claremont](https://tccs-help.claremont.edu/support/solutions/articles/21004960254)).

> **For us.** The identity is a property of the *object and the window*, never
> of sign-in order. A Palmy link carries the identity it belongs to. Opening
> it either goes straight to that identity, or says plainly that the link
> belongs to one of your other identities and offers to open it there. It never
> answers "you need access" to the person who owns both.

## 2. Identity bleed: the wrong self sends the right message

**Outlook picks the sender from context, and sometimes changes it.** Outlook
chooses the From account from "the context of the selected store", and a reply
goes out from the account the message arrived on. Classic Outlook can silently
switch to another account when sending fails. The fix people pass around is a
registry key that forces you to choose an account every time
([Ask Leo](https://askleo.com/why_is_outlook_sending_email_using_the_wrong_account/);
[Microsoft KB 2518195](https://support.microsoft.com/kb/2518195);
[Outlook Tips](https://www.outlook-tips.net/tips/tip-775-ol2010-select-account-before-sending/)).

**Calendar invites go out from whichever account the browser has.** "By
default is always logged into my personal account"
([eM Client forum](https://forum.emclient.com/t/google-calendar-requests-multiple-google-accounts/41795));
the same complaint appears with Calendly
([Calendly community](https://community.calendly.com/how-do-i-40/calendar-invites-are-coming-from-the-wrong-google-account-1512)).
Thunderbird makes the first identity the organiser of every new event
([Mozilla support](https://support.mozilla.org/ln/questions/1584145)).

**Merged photo libraries can't be cleanly separated.** Personal photos land in
a work Apple account, or a personal Apple ID ends up on a work Mac. Macworld
warns the clean-up is irreversible and that deletions spread to every device
([Macworld](https://www.macworld.com/article/614664/untangle-merged-icloud-photos.html)).
Apple Community's advice is a separate macOS user per Apple ID
([thread](https://discussions.apple.com/thread/253958365)).

> **For us.** Sending, inviting and sharing state their identity *before* you
> type, in colour and in words. When nothing determines the identity, the
> system asks rather than defaults: Home's quick-create refuses to guess (see
> `img/06-create-choose-light.png`). Crossing between identities is a named act,
> **carry**, never a side effect.

## 3. Search is the feature people leave over

**Outlook.** New Outlook misses mail that is in the mailbox, which Microsoft
calls "intermittent". It has no local index, and "multi-account search is not
currently supported"
([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/1381535/some-emails-missing-when-search-in-outlook-365);
[Q&A, 2023](https://learn.microsoft.com/en-gb/answers/questions/1303919/new-outlook-missing-items-when-search-indexing-loc)).

**Teams.** Search finds the message but not the conversation around it. A
personal-chat hit opens "a blank screen", and a better search has been coming
"soon" since February 2020
([Tech Community](https://techcommunity.microsoft.com/discussions/microsoftteams/teams-messages-search-function-does-not-show-full-conversation/767924);
[thread](https://techcommunity.microsoft.com/discussions/microsoftteams/teams-search-changed-and-is-now-useless/2737874)).

**Gmail.** Called "remarkably awful", with a commenter adding it was bad
"since before Gemini"
([Language Log, Jul 2026](https://languagelog.ldc.upenn.edu/nll/?p=73926)).
Gmail mobile shows quick results that "disappear when I complete the search"
([HN thread via mirror](https://zeli.app/en/story/49136990)) **[weak]**.

**Drive.** Files orphaned by a deleted parent folder only come back if you know
the query `is:unorganized owner:me`
([Help Desk Geek](https://helpdeskgeek.com/google-drive-files-missing-or-not-visible-heres-how-to-find-them/)).
Drive for desktop lost files in November 2023
([MobileSyrup](https://mobilesyrup.com/2023/11/27/google-drive-users-report-disappearing-files-google-is-investigating/)).

**Proton.** The server can't search encrypted bodies, so users turn on a local
index that "can take quite a while"
([Proton engineering blog](https://proton.me/pl/blog/engineering-message-content-search);
[comparison](https://digdilem.org/thoughts/fastmail-vs-protonmail/)).

**What is loved.** Linear is praised for local-first speed: data on the
client, only deltas from the server, views in tens of milliseconds
([performance.dev](https://performance.dev/what-makes-linear-feel-instant);
[Convex: a map of sync](https://stack.convex.dev/a-map-of-sync)) **[timings weak]**.
Reviewers report Superhuman actions under 100 ms
([G2](https://www.g2.com/products/superhuman-mail/reviews)). macOS Tahoe's
Spotlight overhaul was framed as Apple catching up with Raycast and Alfred
([MacSales](https://eshop.macsales.com/blog/98115-spotlight-gets-supercharged-in-macos-tahoe-your-complete-guide-to-getting-more-out-of-the-default-mac-launcher/);
[Mac Power Users](https://talk.macpowerusers.com/t/so-spotlight-in-macos-tahoe-is-almost-raycast-alfred/40947)).

> **For us.** This is the clearest opening. One index on the device, across
> every kind of object and every identity the window may see, grouped and
> labelled, answering offline. No incumbent has the shape to do this:
> Microsoft's new client has no local index, Google's search is per product,
> and Proton's encryption forces the index onto the device anyway. We put it
> there on purpose, and it is also what keeps a local assistant private.

## 4. Sharing: links that leak, and notifications that phish

- Metomic scanned 6.5M Drive files. About 40% of Drives held sensitive data,
  more than 350,000 files were public to anyone with the link, and 18,000 of
  those were rated critical
  ([Infosecurity, Dec 2023](https://www.infosecurity-magazine.com/news/google-drive-files-contain/)) **[vendor]**.
- A company's staging credentials sat in an "anyone with the link" Doc that
  Google Search indexed
  ([Malwarebytes, Aug 2026](https://www.malwarebytes.com/blog/news/2026/08/be-careful-what-you-put-in-anyone-with-the-link-google-docs)).
- Drive got a spam folder in 2023 because strangers could push files into your
  Drive, with notifications
  ([Workspace Updates, May 2023](https://workspaceupdates.googleblog.com/2023/05/google-drive-spam-folder.html)).
- An admin writes that OneDrive is "very confusing with sharing". Microsoft's
  docs have to explain that "People in your organization" does *not* mean
  everyone in the organisation
  ([Tech Community](https://techcommunity.microsoft.com/discussions/onedriveforbusiness/share-a-folder-with-all-the-organization-not-specifying-each-member/226103/replies/226776);
  [Microsoft Learn](https://learn.microsoft.com/en-ie/Sharepoint/shareable-links-anyone-specific-people-organization)).
- The 2017 Google Docs worm spread through fake "shared a doc with you" mail,
  which shows the share notification itself works as a phishing channel
  ([9to5Google, May 2017](https://9to5google.com/2017/05/03/psa-google-docs-phishing-scam/)).

> **For us.** New shares go to named people by default. A public link expires
> unless you renew it, and it is always visible as public. A share notification
> carries the sharer's *verified* identity and appears only inside the
> recipient identity it was addressed to.

## 5. Notifications: the infinite workday

- Microsoft's own Work Trend Index: people are interrupted "every 2 minutes by
  a meeting, email, or notification", 275 times a day in core hours. They get
  117 emails and 153 Teams messages a day, and 29% are back in their inbox by
  10 pm
  ([Microsoft WorkLab, Jun 2025](https://www.microsoft.com/en-us/worklab/work-trend-index/breaking-down-infinite-workday)) **[opened and checked]**.
- Gloria Mark measured average attention on one screen at about 47 seconds,
  down from about 2.5 minutes in 2004
  ([Steelcase interview](https://www.steelcase.com/research/articles/our-47-second-attention-span-with-gloria-mark-s5-ep3-transcript/);
  [University of California, 2024](https://www.universityofcalifornia.edu/news/how-sharpen-your-attention-and-meet-your-goals-2024)).
  The often-quoted "23 minutes to resume" comes from a study of 36 workers and
  includes the other tasks done in between
  ([Gallup, 2006](https://news.gallup.com/businessjournal/23146/too-many-interruptions-work.aspx)).
- Teams alerts arrive on desktop and phone at once, and messages already read
  come back as unread on mobile
  ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/125566/getting-notifications-duplicated-in-teams-mobile-a);
  [Tech Community](https://techcommunity.microsoft.com/discussions/microsoftteams/a-way-to-stop-duplicate-notifications/3600719)).
- Apple Intelligence summarised a BBC alert into a false claim. The BBC
  complained, and Apple paused news summaries and marked the rest as possibly
  wrong
  ([Silicon UK, Dec 2024](https://silicon.co.uk/ai/bbc-apple-ai-592890);
  [NBC, Jan 2025](https://www.nbcnewyork.com/news/business/money-report/apple-disables-ai-notifications-for-news-in-its-beta-iphone-software/6110884/)).

> **For us.** One delivery per notification, on the device you are using, with
> read state synced. Each identity has its own policy, stated in words (Home's
> rail shows "Northwind · Quiet after 18:00"). An AI summary is always marked
> as one, and is never the only form a message arrives in.

## 6. AI assistants: scope is the whole problem

The incidents all have the same shape. An assistant that can read more than
the task needs reads attacker-controlled content, and can then act or send.

- **Gemini in Gmail.** Hidden zero-size white text in a message rewrote its
  summary into a fake "your password has been compromised" warning with a phone
  number
  ([BleepingComputer, Jul 2025](https://bleepingcomputer.com/news/security/google-gemini-flaw-hijacks-email-summaries-for-phishing)).
- **Turning Gemini off in Gmail is all or nothing.** It also takes Smart
  Features like inbox tabs with it, and the Gemini button stays on screen
  ([404 Media](https://404media.co/opting-out-of-gmails-gemini-ai-summaries-is-a-mess-heres-how-to-do-it-we-think);
  [Decrypt](https://decrypt.co/349491/google-backlash-gmail-setting-gemini-peek-inside-inboxes)).
  A proposed class action alleges Smart Features were switched on by default in
  October 2025
  ([Outlook Business, Nov 2025](https://www.outlookbusiness.com/deeptech/artificial-intelligence/google-faces-lawsuit-over-alleged-secret-activation-of-gemini-ai-across-gmail-chat-meet)).
  A 2026 dismissal was reported but not confirmed.
- **Copilot shows people what they could always reach but never knew existed.**
  Once Copilot was on, employees could read the CEO's email and HR documents,
  because SharePoint permissions had always been loose: "Now when Joe Blow logs
  into an account and kicks off Copilot, they can see everything"
  ([Slashdot summarising Business Insider, Nov 2024](https://yro.slashdot.org/story/24/11/21/2315249/microsoft-copilot-customers-discover-it-can-let-them-read-hr-documents-ceo-emails)).
  Microsoft now publishes an "oversharing blueprint" and Restricted Content
  Discovery
  ([Microsoft Learn](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-blueprint-oversharing)).
- **EchoLeak** (CVE-2025-32711, CVSS 9.3) was a zero-click attack on Copilot.
  One crafted email, pulled in as context, sent data out. Its finders named the
  class an "LLM Scope Violation"
  ([The Hacker News, Jun 2025](https://thehackernews.com/2025/06/zero-click-ai-vulnerability-exposes.html)).
- **Windows Recall** first stored its screenshots and OCR in plaintext SQLite
  that infostealers could read in seconds. It was delayed, made opt-in and
  encrypted
  ([Help Net Security, Jun 2024](https://www.helpnetsecurity.com/2024/06/05/totalrecall-windows-recall-abuse)).
- **Notion agents.** A PDF with hidden text made the agent send client data
  out through its web-search tool, Simon Willison's "lethal trifecta" of
  private data, untrusted content and a way out
  ([simonwillison.net, Sep 2025](https://simonwillison.net/2025/Sep/19/notion-lethal-trifecta)).

> **For us.** This is the strongest argument for the architecture
> `cloud/CONTRACT.md` already fixes. An assistant holds a session scoped to one
> identity, and the database, not the prompt, refuses everything else. On top
> of that: incoming content is untrusted and stripped of hidden text before a
> model sees it. Any outbound action (send, share, fetch a URL) needs explicit
> approval. AI is off by default per identity, and turning it off removes
> nothing else.

## 7. What people love, and what goes wrong with the alternatives

| | loved for | held against it |
| --- | --- | --- |
| Apple Continuity | Universal Clipboard "just works"; once you have it "it's impossible to use a device without one" ([Digital Trends](https://www.digitaltrends.com/computing/apples-continuity-features-are-so-good-they-make-windows-and-android-feel-incomplete/)) | iCloud for Windows is mostly a settings panel; in Nov 2022 it corrupted videos and showed users strangers' photos ([Slashdot](https://apple.slashdot.org/story/22/11/21/2313204/icloud-for-windows-users-report-of-corrupted-videos-photos-from-strangers)) |
| HEY | the Screener holds first-time senders until you accept them ([Fast Company, 2023](https://www.fastcompany.com/90841814/ditching-gmail-for-37signals-hey-email)) | own domains came late, cost extra, and the whole domain has to move ([Brian Li](https://brianli.com/2020/12/custom-domain-support-in-hey-for-you/); [hey.com/domains](https://hey.com/domains)) |
| Superhuman | speed and the keyboard ([G2](https://www.g2.com/products/superhuman-mail/reviews)) | $30 a seat; a sceptic found it no better than Gmail's own shortcuts ([SalesRobot](https://www.salesrobot.co/blogs/superhuman-email-review)) **[weak]** |
| Linear | instant because local-first; opinionated | not covered here |
| Fastmail | Masked Email from 1Password at sign-up ([Fastmail](https://www.fastmail.com/blog/masked-email-from-fastmail-and-1password-protects-your-identity-online/)) | random addresses only; pricey next to SimpleLogin ([1Password community](https://1password.community/discussion/comment/619871)) |
| Google Docs | real-time co-editing replaced passing files around ([Network World](https://www.networkworld.com/article/728016/applications-google-docs-update-puts-more-pressure-on-microsoft-office.html)) | layout fidelity; .docx round-trips lose comments ([Docs help](https://support.google.com/docs/thread/56651062/comments-and-markup-are-not-importing-from-word?hl=en)) |
| Proton | privacy | "slower search and a smaller integration ecosystem are the price" ([GadgetReview](https://www.gadgetreview.com/proton-mail-review-the-inbox-google-cant-read)); Drive on Linux only entered development in June 2026 ([OMG! Ubuntu](https://www.omgubuntu.co.uk/2026/06/proton-drive-linux-client)) |
| Zoho | price and breadth | "a bit dated and clunky", "too cluttered" ([Capterra](https://www.capterra.com/p/174694/Zoho-Mail/reviews/)) |
| Notion | flexibility | slows as workspaces grow; offline only covers recently opened pages ([Capterra](https://www.capterra.com/p/186596/Notion/reviews/?rating=1); [SeaTable](https://seatable.com/notion-experiences/)) |

## 8. Getting out: lock-in and formats

- Large Google Takeout exports fail "with no clear explanation" and have to
  start over. There is no progress bar, and the links expire after about a week
  ([InfoSwitch](https://infoswitch.fr/en/blog/google-takeout-gmail-migration-mbox)) **[vendor]**.
- New Outlook has no CalDAV or CardDAV support, and moderators send people back
  to Classic Outlook
  ([Microsoft Q&A, 2025](https://learn.microsoft.com/en-ie/answers/questions/2156978/install-3rd-apps-new-outllok)).
- Google's CalDAV and Tasks drop due times, recurrence and priorities for
  third-party clients
  ([BusyMac](https://www.busymac.com/docs/faqs/google-calendar-limitations)).
- A .docx file comes back "horrendous" after a trip through Google Docs
  ([Docs help, 2019](https://support.google.com/docs/thread/4313531?hl=en)).

## 9. Price: AI as the reason for an increase

- Google Workspace folded Gemini into its plans and raised prices: Business
  Standard went from $12 to $14, from March 2025 or at renewal
  ([9to5Google, Jan 2025](https://9to5google.com/2025/01/15/google-workspace-gemini-price-increase/)).
- Microsoft 365 Personal and Family rose $3 a month with Copilot bundled in. Only
  "Classic" plans without AI kept the old price
  ([Thurrott](https://www.thurrott.com/cloud/315893/microsoft-365-personal-and-family-plans-get-new-copilot-features-and-a-price-increase)).
- Microsoft 365 commercial plans rose again on 1 July 2026: Business Standard
  went from $12.50 to $14 and E3 from $36 to $39. Sources disagree on some of
  the figures
  ([Redmond, Dec 2025](https://rcpmag.com/articles/2025/12/09/microsoft-365-commercial-subscription-prices-set-to-hike-mid-2026.aspx)).

---

## What we should act on

1. **The identity belongs to the object and the window, never to sign-in
   order.** Links carry it, and opening one lands in the right identity. "You
   need access" is never shown to someone who owns both identities.
2. **Crossing identities is loud and named.** Composing, inviting and sharing
   say who you are before you type. Ambiguity makes the system ask, never
   default. Moving between identities is *carry*: a copy, logged on both sides.
3. **The assistant runs in one identity, enforced by the database.** Treat
   every message and document as hostile input, require approval for anything
   that leaves, and make AI opt-in per identity without taking other features
   with it.
4. **Search is the wedge.** A local index across kinds and identities, grouped
   and labelled, that works offline. It is also the privacy story.
5. **Fewer notifications, delivered once, with a policy written in words.**
   Every AI summary is marked as one.
6. **Leaving is a feature.** CalDAV/CardDAV, IMAP, .docx/.odt, and a resumable,
   visible export, at a time when the incumbents are raising prices to pay for
   AI.
7. **Fix sharing defaults before adding an assistant.** Copilot did not create
   the oversharing; it made it visible. Our scope comes from row-level security,
   and our default shares go to named people.
